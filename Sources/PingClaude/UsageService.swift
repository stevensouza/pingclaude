import Foundation
import Combine
import AppKit

struct UsageWindow: Codable {
    let utilization: Double
    let resets_at: String?
}

struct UsageResponse: Codable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let seven_day_opus: UsageWindow?
    let seven_day_sonnet: UsageWindow?
    let seven_day_cowork: UsageWindow?
    let seven_day_oauth_apps: UsageWindow?
    let extra_usage: UsageWindow?
}

/// Breakdown entry for per-model or special limits (shown only when non-nil)
struct UsageBreakdown {
    let label: String
    let utilization: Double
    let resetsAt: Date?
}

/// Claude subscription plan tier
enum PlanTier: String, CustomStringConvertible {
    case free = "Free"
    case pro = "Pro"
    case max5x = "Max (5x)"
    case max20x = "Max (20x)"
    case team = "Team"
    case enterprise = "Enterprise"
    case unknown = "Unknown"

    var description: String { rawValue }

    /// Parse from API response fields
    static func from(capabilities: [String]?, rateLimitTier: String?) -> PlanTier {
        let tier = rateLimitTier?.lowercased() ?? ""
        let caps = capabilities ?? []

        // Check for Max tiers via rate_limit_tier
        if tier.contains("max_20x") { return .max20x }
        if tier.contains("max_5x") { return .max5x }
        // Check capabilities for max/pro/team/enterprise
        if caps.contains("claude_max") { return .max5x } // default max is 5x
        if caps.contains("enterprise") { return .enterprise }
        if caps.contains("team") { return .team }
        if caps.contains("claude_pro") { return .pro }
        // Free tier has only basic capabilities
        if caps.contains("chat") && caps.count <= 1 { return .free }
        if caps.isEmpty { return .free }
        return .unknown
    }
}

/// Partial decode of organization API response
struct OrgResponse: Codable {
    let capabilities: [String]?
    let rate_limit_tier: String?
    let name: String?
}

struct UsageData {
    let sessionUtilization: Double   // 0-100
    let sessionResetsAt: Date?
    let weeklyUtilization: Double?   // 0-100
    let weeklyResetsAt: Date?
    let breakdowns: [UsageBreakdown] // per-model, cowork, extra — only non-null entries
    let fetchedAt: Date

    var sessionResetsInString: String? {
        guard let resetsAt = sessionResetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSinceNow
        if remaining <= 0 { return "now" }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var sessionResetTimeString: String? {
        guard let resetsAt = sessionResetsAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: resetsAt)
    }
}

class UsageService: ObservableObject {
    private let settingsStore: SettingsStore
    private var logStore: LogStore?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    @Published var latestUsage: UsageData?
    @Published var lastError: String?
    @Published var planTier: PlanTier?
    private var planFetchAttempts: Int = 0
    private var isUpdatingSessionKey = false
    private var consecutiveErrors: Int = 0

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(settingsStore: SettingsStore, logStore: LogStore? = nil) {
        self.settingsStore = settingsStore
        self.logStore = logStore
        setupObservers()
        setupSleepWakeObservers()
    }

    private func setupSleepWakeObservers() {
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopPolling()
        }
        wsnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Wait for network to come up before resuming
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.wakeDelaySeconds) { [weak self] in
                guard let self = self else { return }
                if self.settingsStore.hasUsageAPIConfig {
                    self.consecutiveErrors = 0
                    self.startPolling()
                }
            }
        }
    }

    func startPolling() {
        stopPolling()
        planTier = nil  // Re-fetch plan on credential change
        planFetchAttempts = 0
        consecutiveErrors = 0
        guard settingsStore.hasUsageAPIConfig else { return }

        // Fetch immediately, then schedule next poll after completion
        fetchUsage()
        scheduleNextPoll()

        // Fetch plan tier separately with delay to avoid simultaneous API calls
        fetchPlanIfNeeded()
    }

    /// Fetch plan tier once at startup (skips if already known or max attempts reached)
    func fetchPlanIfNeeded() {
        guard settingsStore.hasUsageAPIConfig else { return }
        guard planTier == nil && planFetchAttempts < 3 else { return }

        let orgId = settingsStore.claudeOrgId
        let cookie = "sessionKey=\(settingsStore.claudeSessionKey)"

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.planFetchDelaySeconds) { [weak self] in
            guard let self = self else { return }
            guard self.planTier == nil && self.planFetchAttempts < 3 else { return }
            self.fetchPlanInfo(orgId: orgId, cookie: cookie)
        }
    }

    /// Manual refresh: fetch usage immediately, then plan after stagger delay
    func refreshAll() {
        guard settingsStore.hasUsageAPIConfig else { return }

        let orgId = settingsStore.claudeOrgId
        let cookie = "sessionKey=\(settingsStore.claudeSessionKey)"

        fetchUsageData(orgId: orgId, cookie: cookie)

        planFetchAttempts = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.planFetchDelaySeconds) { [weak self] in
            guard let self = self else { return }
            self.fetchPlanInfo(orgId: orgId, cookie: cookie)
        }
    }

    private func scheduleNextPoll() {
        timer?.invalidate()
        let baseInterval = TimeInterval(settingsStore.usagePollingSeconds)
        let delay: TimeInterval
        if consecutiveErrors > 0 {
            // Exponential backoff: base * 2^errors, capped at max
            let backoff = baseInterval * pow(2.0, Double(consecutiveErrors))
            delay = min(backoff, Constants.usageMaxBackoffSeconds)
        } else {
            delay = baseInterval
        }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.fetchUsage()
            self?.scheduleNextPoll()
        }
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func fetchUsage() {
        guard settingsStore.hasUsageAPIConfig else { return }

        let orgId = settingsStore.claudeOrgId
        let cookie = "sessionKey=\(settingsStore.claudeSessionKey)"

        fetchUsageData(orgId: orgId, cookie: cookie)
    }

    private func fetchUsageData(orgId: String, cookie: String) {
        let urlString = "\(Constants.usageAPIBase)/\(orgId)/usage"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    self.consecutiveErrors += 1
                    self.lastError = error.localizedDescription
                    self.logStore?.log("Usage API error: \(error.localizedDescription)")
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.lastError = "Invalid response"
                    self.logStore?.log("Usage API error: invalid response")
                    return
                }

                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    self.lastError = "Auth expired \u{2014} update session key in Settings"
                    self.logStore?.log("Usage API auth error: HTTP \(httpResponse.statusCode)")
                    return
                }

                if httpResponse.statusCode == 429 {
                    self.consecutiveErrors += 1
                    self.lastError = "Rate limited \u{2014} backing off"
                    let backoff = min(Double(self.settingsStore.usagePollingSeconds) * pow(2.0, Double(self.consecutiveErrors)), Constants.usageMaxBackoffSeconds)
                    self.logStore?.log("Usage API rate limited (429), next poll in \(Int(backoff))s (attempt \(self.consecutiveErrors))")
                    self.scheduleNextPoll()
                    return
                }

                guard httpResponse.statusCode == 200, let data = data else {
                    self.consecutiveErrors += 1
                    self.lastError = "HTTP \(httpResponse.statusCode)"
                    self.logStore?.log("Usage API error: HTTP \(httpResponse.statusCode)")
                    return
                }

                // Update session key if server sends a different one (without triggering polling restart)
                if let setCookie = httpResponse.value(forHTTPHeaderField: "Set-Cookie"),
                   let newKey = self.extractSessionKey(from: setCookie),
                   newKey != self.settingsStore.claudeSessionKey {
                    self.isUpdatingSessionKey = true
                    self.settingsStore.claudeSessionKey = newKey
                    self.isUpdatingSessionKey = false
                }

                do {
                    let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)

                    // Build breakdowns for non-null per-model/special limits
                    var breakdowns: [UsageBreakdown] = []
                    let optionalEntries: [(String, UsageWindow?)] = [
                        ("Opus (7d)", decoded.seven_day_opus),
                        ("Sonnet (7d)", decoded.seven_day_sonnet),
                        ("Cowork (7d)", decoded.seven_day_cowork),
                        ("OAuth apps (7d)", decoded.seven_day_oauth_apps),
                        ("Extra usage", decoded.extra_usage),
                    ]
                    for (label, window) in optionalEntries {
                        if let w = window {
                            breakdowns.append(UsageBreakdown(
                                label: label,
                                utilization: w.utilization,
                                resetsAt: self.parseDate(w.resets_at)
                            ))
                        }
                    }

                    let usage = UsageData(
                        sessionUtilization: decoded.five_hour?.utilization ?? 0,
                        sessionResetsAt: self.parseDate(decoded.five_hour?.resets_at),
                        weeklyUtilization: decoded.seven_day?.utilization,
                        weeklyResetsAt: self.parseDate(decoded.seven_day?.resets_at),
                        breakdowns: breakdowns,
                        fetchedAt: Date()
                    )
                    self.latestUsage = usage
                    self.lastError = nil
                    self.consecutiveErrors = 0

                    // Log key usage values
                    var logParts = ["Usage API OK: session=\(Int(usage.sessionUtilization))%"]
                    if let weekly = usage.weeklyUtilization { logParts.append("weekly=\(Int(weekly))%") }
                    if let resetStr = usage.sessionResetsInString { logParts.append("resets=\(resetStr)") }
                    self.logStore?.log(logParts.joined(separator: ", "))
                } catch {
                    self.lastError = "Parse error: \(error.localizedDescription)"
                    self.logStore?.log("Usage API parse error: \(error.localizedDescription)")
                }
            }
        }.resume()
    }

    private func fetchPlanInfo(orgId: String, cookie: String) {
        let urlString = "\(Constants.usageAPIBase)/\(orgId)"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.planFetchAttempts += 1

                if let error = error {
                    self.logStore?.log("Plan API error (attempt \(self.planFetchAttempts)/3): \(error.localizedDescription)")
                    NSLog("PingClaude: Plan fetch failed (attempt %d/3): %@", self.planFetchAttempts, error.localizedDescription)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.logStore?.log("Plan API error (attempt \(self.planFetchAttempts)/3): invalid response")
                    NSLog("PingClaude: Plan fetch failed (attempt %d/3): invalid response", self.planFetchAttempts)
                    return
                }

                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    self.logStore?.log("Plan API auth error: HTTP \(httpResponse.statusCode)")
                    NSLog("PingClaude: Plan fetch auth error (HTTP %d) — update session key", httpResponse.statusCode)
                    self.planFetchAttempts = 3  // Stop retrying with bad credentials
                    return
                }

                guard httpResponse.statusCode == 200, let data = data else {
                    self.logStore?.log("Plan API error (attempt \(self.planFetchAttempts)/3): HTTP \(httpResponse.statusCode)")
                    NSLog("PingClaude: Plan fetch failed (attempt %d/3): HTTP %d", self.planFetchAttempts, httpResponse.statusCode)
                    return
                }

                // Update session key if server sends a different one (without triggering polling restart)
                if let setCookie = httpResponse.value(forHTTPHeaderField: "Set-Cookie"),
                   let newKey = self.extractSessionKey(from: setCookie),
                   newKey != self.settingsStore.claudeSessionKey {
                    self.isUpdatingSessionKey = true
                    self.settingsStore.claudeSessionKey = newKey
                    self.isUpdatingSessionKey = false
                }

                do {
                    let decoded = try JSONDecoder().decode(OrgResponse.self, from: data)
                    self.planTier = PlanTier.from(
                        capabilities: decoded.capabilities,
                        rateLimitTier: decoded.rate_limit_tier
                    )
                    self.logStore?.log("Plan API OK: \(self.planTier?.description ?? "unknown")")
                } catch {
                    self.logStore?.log("Plan API parse error (attempt \(self.planFetchAttempts)/3): \(error.localizedDescription)")
                    NSLog("PingClaude: Plan fetch parse error (attempt %d/3): %@", self.planFetchAttempts, error.localizedDescription)
                }
            }
        }.resume()
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        return isoFormatter.date(from: string) ?? isoFormatterNoFrac.date(from: string)
    }

    private func extractSessionKey(from setCookie: String) -> String? {
        // Parse "sessionKey=sk-ant-...; Domain=..." from Set-Cookie header
        let parts = setCookie.components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("sessionKey=") {
                return String(trimmed.dropFirst("sessionKey=".count))
            }
        }
        return nil
    }

    private func setupObservers() {
        // Restart polling when config changes
        Publishers.CombineLatest3(
            settingsStore.$claudeSessionKey,
            settingsStore.$claudeOrgId,
            settingsStore.$usagePollingSeconds
        )
        .dropFirst()
        .debounce(for: .seconds(1), scheduler: RunLoop.main)
        .sink { [weak self] _, _, _ in
            guard let self = self, !self.isUpdatingSessionKey else { return }
            self.startPolling()
        }
        .store(in: &cancellables)
    }

    deinit {
        timer?.invalidate()
    }
}
