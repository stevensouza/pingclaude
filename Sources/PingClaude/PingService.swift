import Foundation
import Combine

enum PingStatus: String {
    case idle
    case pinging
    case success
    case error
}

enum PingMethod: String {
    case api
    case cli
}

/// Usage data extracted from the SSE `message_limit` event during an API ping
struct PingUsageData {
    let sessionUtilization: Double?   // 0-1 scale
    let sessionResetsAt: Double?      // unix timestamp
    let weeklyUtilization: Double?
    let weeklyResetsAt: Double?       // unix timestamp
    let overageUtilization: Double?
    let overageResetsAt: Double?      // unix timestamp
}

struct PingResult {
    let id: UUID
    let timestamp: Date
    let status: PingStatus
    let duration: TimeInterval
    let command: String
    let response: String
    let errorMessage: String?
    let method: PingMethod
    let usageFromPing: PingUsageData?
    let apiURL: String?   // API endpoint URL (no sensitive data)
    let model: String?    // Full model name used
}

/// Simple error wrapper for API results
struct PingError: Error {
    let message: String
}

class PingService: ObservableObject {
    private let settingsStore: SettingsStore
    @Published var currentStatus: PingStatus = .idle
    @Published var lastPingTime: Date?
    @Published var lastPingUsageData: PingUsageData?
    private var currentProcess: Process?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /// Whether API-based pinging is available (orgId + sessionKey configured)
    var canPingViaAPI: Bool {
        settingsStore.hasUsageAPIConfig
    }

    func ping(completion: @escaping (PingResult) -> Void) {
        guard currentStatus != .pinging else { return }

        DispatchQueue.main.async {
            self.currentStatus = .pinging
        }

        if canPingViaAPI {
            pingViaAPI(completion: completion)
        } else {
            pingViaCLI(completion: completion)
        }
    }

    // MARK: - API-Based Ping

    private func pingViaAPI(completion: @escaping (PingResult) -> Void) {
        let orgId = settingsStore.claudeOrgId
        let sessionKey = settingsStore.claudeSessionKey
        let cookie = "sessionKey=\(sessionKey)"
        let prompt = settingsStore.pingPrompt
        let model = settingsStore.pingModel
        let apiModel = Constants.apiModelNames[model] ?? "claude-haiku-4-5-20251001"
        let startTime = Date()
        let commandDesc = "API: \(prompt) [\(model)]"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Step 1: Create conversation
            let convUuid = UUID().uuidString.lowercased()
            let createResult = self.createConversation(orgId: orgId, cookie: cookie, uuid: convUuid)
            let completionURL = "\(Constants.usageAPIBase)/\(orgId)/chat_conversations/\(convUuid)/completion"

            switch createResult {
            case .failure(let error):
                self.finishPing(
                    startTime: startTime,
                    status: .error,
                    command: commandDesc,
                    response: "",
                    errorMessage: "Create conversation failed: \(error.message)",
                    method: .api,
                    usageData: nil,
                    newSessionKey: nil,
                    apiURL: completionURL,
                    model: apiModel,
                    completion: completion
                )
                return

            case .success(let newCookie):
                // Update session key if refreshed
                let activeCookie = newCookie ?? cookie

                // Step 2: Send message
                let sendResult = self.sendMessage(
                    orgId: orgId,
                    cookie: activeCookie,
                    convUuid: convUuid,
                    prompt: prompt,
                    model: apiModel
                )

                // Step 3: Delete conversation (fire-and-forget)
                self.deleteConversation(orgId: orgId, cookie: activeCookie, convUuid: convUuid)

                switch sendResult {
                case .failure(let error):
                    self.finishPing(
                        startTime: startTime,
                        status: .error,
                        command: commandDesc,
                        response: "",
                        errorMessage: error.message,
                        method: .api,
                        usageData: nil,
                        newSessionKey: self.extractSessionKeyValue(from: activeCookie),
                        apiURL: completionURL,
                        model: apiModel,
                        completion: completion
                    )

                case .success(let (responseText, usageData, latestCookie)):
                    self.finishPing(
                        startTime: startTime,
                        status: .success,
                        command: commandDesc,
                        response: responseText,
                        errorMessage: nil,
                        method: .api,
                        usageData: usageData,
                        newSessionKey: latestCookie,
                        apiURL: completionURL,
                        model: apiModel,
                        completion: completion
                    )
                }
            }
        }
    }

    /// Create a temporary conversation. Returns .success with optional new cookie, or .failure with error string.
    private func createConversation(orgId: String, cookie: String, uuid: String) -> Result<String?, PingError> {
        let urlString = "\(Constants.usageAPIBase)/\(orgId)/chat_conversations"
        guard let url = URL(string: urlString) else {
            return .failure(PingError(message: "Invalid URL"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = Constants.apiPingTimeoutSeconds

        let body: [String: Any] = [
            "uuid": uuid,
            "name": "",
            "include_conversation_preferences": true,
            "is_temporary": true
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String?, PingError> = .failure(PingError(message: "No response"))

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                result = .failure(PingError(message: error.localizedDescription))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                result = .failure(PingError(message: "Invalid response"))
                return
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                result = .failure(PingError(message: "Auth expired \u{2014} update session key"))
                return
            }

            guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                result = .failure(PingError(message: "HTTP \(httpResponse.statusCode): \(String(body.prefix(200)))"))
                return
            }

            // Extract refreshed session key if present
            var newCookie: String? = nil
            if let setCookie = httpResponse.value(forHTTPHeaderField: "Set-Cookie"),
               let newKey = self.extractSessionKey(from: setCookie) {
                newCookie = "sessionKey=\(newKey)"
            }

            result = .success(newCookie)
        }.resume()

        semaphore.wait()
        return result
    }

    /// Send the ping message and parse SSE response. Returns (responseText, usageData, newCookie) or error.
    private func sendMessage(
        orgId: String,
        cookie: String,
        convUuid: String,
        prompt: String,
        model: String
    ) -> Result<(String, PingUsageData?, String?), PingError> {
        let urlString = "\(Constants.usageAPIBase)/\(orgId)/chat_conversations/\(convUuid)/completion"
        guard let url = URL(string: urlString) else {
            return .failure(PingError(message: "Invalid URL"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = Constants.apiPingTimeoutSeconds

        let body: [String: Any] = [
            "prompt": prompt,
            "parent_message_uuid": "00000000-0000-4000-8000-000000000000",
            "model": model,
            "timezone": TimeZone.current.identifier,
            "attachments": [],
            "files": [],
            "tools": [],
            "rendering_mode": "messages",
            "sync_sources": [],
            "locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(String, PingUsageData?, String?), PingError> = .failure(PingError(message: "No response"))

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            defer { semaphore.signal() }
            guard let self = self else { return }

            if let error = error {
                result = .failure(PingError(message: error.localizedDescription))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                result = .failure(PingError(message: "Invalid response"))
                return
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                result = .failure(PingError(message: "Auth expired \u{2014} update session key"))
                return
            }

            guard httpResponse.statusCode == 200, let data = data else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                result = .failure(PingError(message: "HTTP \(httpResponse.statusCode): \(String(body.prefix(200)))"))
                return
            }

            // Extract refreshed session key
            var newCookie: String? = nil
            if let setCookie = httpResponse.value(forHTTPHeaderField: "Set-Cookie"),
               let newKey = self.extractSessionKey(from: setCookie) {
                newCookie = newKey
            }

            // Parse SSE response
            let (responseText, usageData) = self.parseSSEResponse(data)
            result = .success((responseText, usageData, newCookie))
        }.resume()

        semaphore.wait()
        return result
    }

    /// Delete conversation (fire-and-forget, best effort)
    private func deleteConversation(orgId: String, cookie: String, convUuid: String) {
        let urlString = "\(Constants.usageAPIBase)/\(orgId)/chat_conversations/\(convUuid)"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: - SSE Parsing

    /// Parse SSE event stream. Returns (collected response text, optional usage data).
    private func parseSSEResponse(_ data: Data) -> (String, PingUsageData?) {
        guard let body = String(data: data, encoding: .utf8) else {
            return ("", nil)
        }

        var responseText = ""
        var usageData: PingUsageData? = nil

        // SSE format varies:
        //   event: <type>\ndata: <json>\n\n     (data on same line)
        //   event: <type>\ndata:\n<json>\n\n    (data on next line)
        let lines = body.components(separatedBy: "\n")
        var currentEvent = ""
        var expectingData = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("event:") {
                currentEvent = String(trimmed.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                expectingData = false
            } else if trimmed.hasPrefix("data:") {
                // Extract everything after "data:" (with or without space)
                var payload = String(trimmed.dropFirst("data:".count))
                if payload.hasPrefix(" ") {
                    payload = String(payload.dropFirst())
                }
                if payload.isEmpty {
                    // JSON will be on the next line
                    expectingData = true
                } else {
                    processSSEData(event: currentEvent, json: payload, responseText: &responseText, usageData: &usageData)
                    expectingData = false
                }
            } else if expectingData && !trimmed.isEmpty {
                // Data payload on line after "data:"
                processSSEData(event: currentEvent, json: trimmed, responseText: &responseText, usageData: &usageData)
                expectingData = false
            } else if trimmed.isEmpty {
                expectingData = false
            }
        }

        return (responseText, usageData)
    }

    private func processSSEData(event: String, json: String, responseText: inout String, usageData: inout PingUsageData?) {
        switch event {
        case "content_block_delta":
            if let text = extractDeltaText(from: json) {
                responseText += text
            }
        case "message_limit":
            usageData = parseMessageLimit(from: json)
        case "error":
            if let errorMsg = extractErrorMessage(from: json) {
                responseText = "Error: \(errorMsg)"
            }
        default:
            break
        }
    }

    /// Extract text from a content_block_delta SSE data payload
    private func extractDeltaText(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let delta = obj["delta"] as? [String: Any],
              let text = delta["text"] as? String else {
            return nil
        }
        return text
    }

    /// Parse message_limit SSE event for usage data
    private func parseMessageLimit(from json: String) -> PingUsageData? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // The windows are nested: {"type":"message_limit","message_limit":{...,"windows":{...}}}
        let limitObj = obj["message_limit"] as? [String: Any] ?? obj
        guard let windows = limitObj["windows"] as? [String: Any] else {
            return nil
        }

        let fiveH = windows["5h"] as? [String: Any]
        let sevenD = windows["7d"] as? [String: Any]
        let overage = windows["overage"] as? [String: Any]

        return PingUsageData(
            sessionUtilization: fiveH?["utilization"] as? Double,
            sessionResetsAt: asDouble(fiveH?["resets_at"]),
            weeklyUtilization: sevenD?["utilization"] as? Double,
            weeklyResetsAt: asDouble(sevenD?["resets_at"]),
            overageUtilization: overage?["utilization"] as? Double,
            overageResetsAt: asDouble(overage?["resets_at"])
        )
    }

    /// Convert a value that might be Int, Double, or String to Double (unix timestamp)
    private func asDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Extract error message from an error SSE event
    private func extractErrorMessage(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["error"] as? String ?? obj["message"] as? String
    }

    // MARK: - CLI-Based Ping

    private func pingViaCLI(completion: @escaping (PingResult) -> Void) {
        let claudePath = settingsStore.claudePath
        let prompt = settingsStore.pingPrompt
        let model = settingsStore.pingModel

        let args = ["-p", prompt, "--model", model, "--max-turns", "1"]
        let command = "\(claudePath) \(args.joined(separator: " "))"
        let startTime = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = args
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            // Run from /tmp to avoid macOS TCC prompts for protected folders
            process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")

            // Set PATH so claude CLI can find its dependencies
            var env = ProcessInfo.processInfo.environment
            let existingPath = env["PATH"] ?? ""
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:\(existingPath)"
            process.environment = env

            self.currentProcess = process

            // Timeout timer
            let timeoutItem = DispatchWorkItem { [weak process] in
                if let p = process, p.isRunning {
                    p.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + Constants.pingTimeoutSeconds,
                execute: timeoutItem
            )

            do {
                try process.run()
                process.waitUntilExit()
                timeoutItem.cancel()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let exitCode = process.terminationStatus
                let status: PingStatus = exitCode == 0 ? .success : .error

                self.finishPing(
                    startTime: startTime,
                    status: status,
                    command: command,
                    response: output,
                    errorMessage: exitCode != 0 ? (errorOutput.isEmpty ? "Exit code \(exitCode)" : errorOutput) : nil,
                    method: .cli,
                    usageData: nil,
                    newSessionKey: nil,
                    model: model,
                    completion: completion
                )
            } catch {
                self.finishPing(
                    startTime: startTime,
                    status: .error,
                    command: command,
                    response: "",
                    errorMessage: error.localizedDescription,
                    method: .cli,
                    usageData: nil,
                    newSessionKey: nil,
                    model: model,
                    completion: completion
                )
            }
        }
    }

    // MARK: - Helpers

    private func finishPing(
        startTime: Date,
        status: PingStatus,
        command: String,
        response: String,
        errorMessage: String?,
        method: PingMethod,
        usageData: PingUsageData?,
        newSessionKey: String?,
        apiURL: String? = nil,
        model: String? = nil,
        completion: @escaping (PingResult) -> Void
    ) {
        let duration = Date().timeIntervalSince(startTime)
        let result = PingResult(
            id: UUID(),
            timestamp: startTime,
            status: status,
            duration: duration,
            command: command,
            response: response,
            errorMessage: errorMessage,
            method: method,
            usageFromPing: usageData,
            apiURL: apiURL,
            model: model
        )

        DispatchQueue.main.async {
            // Update session key if refreshed
            if let newKey = newSessionKey {
                self.settingsStore.claudeSessionKey = newKey
            }

            self.currentStatus = status
            self.lastPingTime = startTime
            self.lastPingUsageData = usageData
            self.currentProcess = nil
            completion(result)

            // Reset to idle after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if self.currentStatus == .success || self.currentStatus == .error {
                    self.currentStatus = .idle
                }
            }
        }
    }

    private func extractSessionKey(from setCookie: String) -> String? {
        let parts = setCookie.components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("sessionKey=") {
                return String(trimmed.dropFirst("sessionKey=".count))
            }
        }
        return nil
    }

    /// Extract the raw session key value from a "sessionKey=sk-ant-..." cookie string
    private func extractSessionKeyValue(from cookie: String) -> String? {
        if cookie.hasPrefix("sessionKey=") {
            return String(cookie.dropFirst("sessionKey=".count))
        }
        return nil
    }
}
