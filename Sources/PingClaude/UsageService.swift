import Foundation
import Combine

struct UsageWindow: Codable {
    let utilization: Double
    let resets_at: String
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

struct SpendResponse: Codable {
    let monthly_credit_limit: Int?
    let used_credits: Int?
    let out_of_credits: Bool?
    let is_enabled: Bool?
}

struct UsageData {
    let sessionUtilization: Double   // 0-100
    let sessionResetsAt: Date?
    let weeklyUtilization: Double?   // 0-100
    let weeklyResetsAt: Date?
    let breakdowns: [UsageBreakdown] // per-model, cowork, extra — only non-null entries
    let monthlyLimitCents: Int?      // e.g. 5000 = $50
    let monthlyUsedCents: Int?       // e.g. 2405 = $24.05
    let outOfCredits: Bool?
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
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    @Published var latestUsage: UsageData?
    @Published var lastError: String?

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

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        setupObservers()
    }

    func startPolling() {
        stopPolling()
        guard settingsStore.hasUsageAPIConfig else { return }

        // Fetch immediately
        fetchUsage()

        // Then poll on interval
        let interval = TimeInterval(settingsStore.usagePollingSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchUsage()
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

        // Fetch both usage and spend data in parallel
        fetchUsageData(orgId: orgId, cookie: cookie)
        fetchSpendData(orgId: orgId, cookie: cookie)
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
                    self.lastError = error.localizedDescription
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.lastError = "Invalid response"
                    return
                }

                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    self.lastError = "Auth expired \u{2014} update session key in Settings"
                    return
                }

                guard httpResponse.statusCode == 200, let data = data else {
                    self.lastError = "HTTP \(httpResponse.statusCode)"
                    return
                }

                // Update session key if server sends a different one
                if let setCookie = httpResponse.value(forHTTPHeaderField: "Set-Cookie"),
                   let newKey = self.extractSessionKey(from: setCookie),
                   newKey != self.settingsStore.claudeSessionKey {
                    self.settingsStore.claudeSessionKey = newKey
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

                    // Preserve spend data from previous fetch if available
                    let prevSpend = self.latestUsage

                    let usage = UsageData(
                        sessionUtilization: decoded.five_hour?.utilization ?? 0,
                        sessionResetsAt: self.parseDate(decoded.five_hour?.resets_at),
                        weeklyUtilization: decoded.seven_day?.utilization,
                        weeklyResetsAt: self.parseDate(decoded.seven_day?.resets_at),
                        breakdowns: breakdowns,
                        monthlyLimitCents: prevSpend?.monthlyLimitCents,
                        monthlyUsedCents: prevSpend?.monthlyUsedCents,
                        outOfCredits: prevSpend?.outOfCredits,
                        fetchedAt: Date()
                    )
                    self.latestUsage = usage
                    self.lastError = nil
                } catch {
                    self.lastError = "Parse error: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    private func fetchSpendData(orgId: String, cookie: String) {
        let urlString = "\(Constants.usageAPIBase)/\(orgId)/overage_spend_limit"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200,
                      let data = data else { return }

                // Update session key if server sends a different one
                if let setCookie = httpResponse.value(forHTTPHeaderField: "Set-Cookie"),
                   let newKey = self.extractSessionKey(from: setCookie),
                   newKey != self.settingsStore.claudeSessionKey {
                    self.settingsStore.claudeSessionKey = newKey
                }

                if let decoded = try? JSONDecoder().decode(SpendResponse.self, from: data),
                   let existing = self.latestUsage {
                    // Merge spend data into existing usage data
                    self.latestUsage = UsageData(
                        sessionUtilization: existing.sessionUtilization,
                        sessionResetsAt: existing.sessionResetsAt,
                        weeklyUtilization: existing.weeklyUtilization,
                        weeklyResetsAt: existing.weeklyResetsAt,
                        breakdowns: existing.breakdowns,
                        monthlyLimitCents: decoded.monthly_credit_limit,
                        monthlyUsedCents: decoded.used_credits,
                        outOfCredits: decoded.out_of_credits,
                        fetchedAt: existing.fetchedAt
                    )
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
            self?.startPolling()
        }
        .store(in: &cancellables)
    }

    deinit {
        timer?.invalidate()
    }
}
