import Foundation

enum Constants {
    static let bundleID = "com.pingclaude.app"
    static let appName = "PingClaude"

    // UserDefaults keys
    enum Keys {
        static let claudePath = "claudePath"
        static let pingPrompt = "pingPrompt"
        static let pingModel = "pingModel"
        static let scheduleEnabled = "scheduleEnabled"
        static let scheduleMode = "scheduleMode"
        static let intervalMinutes = "intervalMinutes"
        static let windowStartHour = "windowStartHour"
        static let windowStartMinute = "windowStartMinute"
        static let windowEndHour = "windowEndHour"
        static let windowEndMinute = "windowEndMinute"
        static let logFolder = "logFolder"
        static let maxLogSizeMB = "maxLogSizeMB"
        static let launchAtLogin = "launchAtLogin"
        static let resetWindowHours = "resetWindowHours"
        static let pingOnWake = "pingOnWake"
        static let pingOnStartup = "pingOnStartup"
        static let claudeSessionKey = "claudeSessionKey"
        static let claudeOrgId = "claudeOrgId"
        static let usagePollingMinutes = "usagePollingMinutes" // legacy
        static let usagePollingSeconds = "usagePollingSeconds"
    }

    // Default values
    enum Defaults {
        static let claudePath = "/usr/local/bin/claude"
        static let pingPrompt = "hi"
        static let pingModel = "haiku"
        static let scheduleEnabled = false
        static let scheduleMode = "allDay" // "allDay" or "timeWindow"
        static let intervalMinutes = 60
        static let windowStartHour = 6
        static let windowStartMinute = 0
        static let windowEndHour = 10
        static let windowEndMinute = 0
        static let maxLogSizeMB = 10
        static let resetWindowHours = 5
        static let pingOnWake = true
        static let pingOnStartup = true

        static var logFolder: String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return "\(home)/Library/Logs/PingClaude"
        }
    }

    // Usage API
    static let usageAPIBase = "https://claude.ai/api/organizations"

    // Subprocess
    static let pingTimeoutSeconds: TimeInterval = 30
    static let wakeDelaySeconds: TimeInterval = 5

    // Available models
    static let availableModels = ["haiku", "sonnet", "opus"]

    // API model name mappings (for claude.ai web API)
    static let apiModelNames: [String: String] = [
        "haiku": "claude-haiku-4-5-20251001",
        "sonnet": "claude-sonnet-4-5-20250929",
        "opus": "claude-opus-4-6"
    ]

    // API ping timeout (longer than CLI since it involves create + send + delete)
    static let apiPingTimeoutSeconds: TimeInterval = 45

    // Interval options (in minutes)
    static let intervalOptions: [(label: String, minutes: Int)] = [
        ("15 minutes", 15),
        ("30 minutes", 30),
        ("1 hour", 60),
        ("2 hours", 120),
        ("4 hours", 240)
    ]
}
