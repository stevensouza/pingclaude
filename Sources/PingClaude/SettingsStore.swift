import Foundation
import Combine
import ServiceManagement

class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var claudePath: String {
        didSet { defaults.set(claudePath, forKey: Constants.Keys.claudePath) }
    }
    @Published var pingPrompt: String {
        didSet { defaults.set(pingPrompt, forKey: Constants.Keys.pingPrompt) }
    }
    @Published var pingModel: String {
        didSet { defaults.set(pingModel, forKey: Constants.Keys.pingModel) }
    }
    @Published var scheduleEnabled: Bool {
        didSet { defaults.set(scheduleEnabled, forKey: Constants.Keys.scheduleEnabled) }
    }
    @Published var scheduleMode: String {
        didSet { defaults.set(scheduleMode, forKey: Constants.Keys.scheduleMode) }
    }
    @Published var intervalMinutes: Int {
        didSet { defaults.set(intervalMinutes, forKey: Constants.Keys.intervalMinutes) }
    }
    @Published var windowStartHour: Int {
        didSet { defaults.set(windowStartHour, forKey: Constants.Keys.windowStartHour) }
    }
    @Published var windowStartMinute: Int {
        didSet { defaults.set(windowStartMinute, forKey: Constants.Keys.windowStartMinute) }
    }
    @Published var windowEndHour: Int {
        didSet { defaults.set(windowEndHour, forKey: Constants.Keys.windowEndHour) }
    }
    @Published var windowEndMinute: Int {
        didSet { defaults.set(windowEndMinute, forKey: Constants.Keys.windowEndMinute) }
    }
    @Published var logFolder: String {
        didSet { defaults.set(logFolder, forKey: Constants.Keys.logFolder) }
    }
    @Published var maxLogSizeMB: Int {
        didSet { defaults.set(maxLogSizeMB, forKey: Constants.Keys.maxLogSizeMB) }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Constants.Keys.launchAtLogin)
            updateLaunchAtLogin()
        }
    }
    @Published var resetWindowHours: Int {
        didSet { defaults.set(resetWindowHours, forKey: Constants.Keys.resetWindowHours) }
    }
    @Published var pingOnWake: Bool {
        didSet { defaults.set(pingOnWake, forKey: Constants.Keys.pingOnWake) }
    }
    @Published var pingOnStartup: Bool {
        didSet { defaults.set(pingOnStartup, forKey: Constants.Keys.pingOnStartup) }
    }
    @Published var claudeSessionKey: String {
        didSet { defaults.set(claudeSessionKey, forKey: Constants.Keys.claudeSessionKey) }
    }
    @Published var claudeOrgId: String {
        didSet { defaults.set(claudeOrgId, forKey: Constants.Keys.claudeOrgId) }
    }
    @Published var usagePollingSeconds: Int {
        didSet { defaults.set(usagePollingSeconds, forKey: Constants.Keys.usagePollingSeconds) }
    }

    /// Whether we have enough config to poll the usage API
    var hasUsageAPIConfig: Bool {
        !claudeSessionKey.isEmpty && !claudeOrgId.isEmpty
    }

    init() {
        // Register defaults for first launch
        defaults.register(defaults: [
            Constants.Keys.claudePath: Constants.Defaults.claudePath,
            Constants.Keys.pingPrompt: Constants.Defaults.pingPrompt,
            Constants.Keys.pingModel: Constants.Defaults.pingModel,
            Constants.Keys.scheduleEnabled: Constants.Defaults.scheduleEnabled,
            Constants.Keys.scheduleMode: Constants.Defaults.scheduleMode,
            Constants.Keys.intervalMinutes: Constants.Defaults.intervalMinutes,
            Constants.Keys.windowStartHour: Constants.Defaults.windowStartHour,
            Constants.Keys.windowStartMinute: Constants.Defaults.windowStartMinute,
            Constants.Keys.windowEndHour: Constants.Defaults.windowEndHour,
            Constants.Keys.windowEndMinute: Constants.Defaults.windowEndMinute,
            Constants.Keys.logFolder: Constants.Defaults.logFolder,
            Constants.Keys.maxLogSizeMB: Constants.Defaults.maxLogSizeMB,
            Constants.Keys.launchAtLogin: false,
            Constants.Keys.resetWindowHours: Constants.Defaults.resetWindowHours,
            Constants.Keys.pingOnWake: Constants.Defaults.pingOnWake,
            Constants.Keys.pingOnStartup: Constants.Defaults.pingOnStartup,
            Constants.Keys.claudeSessionKey: "",
            Constants.Keys.claudeOrgId: "",
            Constants.Keys.usagePollingSeconds: 60
        ])

        // Load values
        claudePath = defaults.string(forKey: Constants.Keys.claudePath) ?? Constants.Defaults.claudePath
        pingPrompt = defaults.string(forKey: Constants.Keys.pingPrompt) ?? Constants.Defaults.pingPrompt
        pingModel = defaults.string(forKey: Constants.Keys.pingModel) ?? Constants.Defaults.pingModel
        scheduleEnabled = defaults.bool(forKey: Constants.Keys.scheduleEnabled)
        scheduleMode = defaults.string(forKey: Constants.Keys.scheduleMode) ?? Constants.Defaults.scheduleMode
        intervalMinutes = defaults.integer(forKey: Constants.Keys.intervalMinutes)
        windowStartHour = defaults.integer(forKey: Constants.Keys.windowStartHour)
        windowStartMinute = defaults.integer(forKey: Constants.Keys.windowStartMinute)
        windowEndHour = defaults.integer(forKey: Constants.Keys.windowEndHour)
        windowEndMinute = defaults.integer(forKey: Constants.Keys.windowEndMinute)
        logFolder = defaults.string(forKey: Constants.Keys.logFolder) ?? Constants.Defaults.logFolder
        maxLogSizeMB = defaults.integer(forKey: Constants.Keys.maxLogSizeMB)
        launchAtLogin = defaults.bool(forKey: Constants.Keys.launchAtLogin)
        resetWindowHours = defaults.integer(forKey: Constants.Keys.resetWindowHours)
        pingOnWake = defaults.bool(forKey: Constants.Keys.pingOnWake)
        pingOnStartup = defaults.bool(forKey: Constants.Keys.pingOnStartup)
        claudeSessionKey = defaults.string(forKey: Constants.Keys.claudeSessionKey) ?? ""
        claudeOrgId = defaults.string(forKey: Constants.Keys.claudeOrgId) ?? ""

        // Migrate old usagePollingMinutes → usagePollingSeconds
        if defaults.contains(key: Constants.Keys.usagePollingSeconds) {
            usagePollingSeconds = defaults.integer(forKey: Constants.Keys.usagePollingSeconds)
        } else if defaults.contains(key: Constants.Keys.usagePollingMinutes) {
            usagePollingSeconds = defaults.integer(forKey: Constants.Keys.usagePollingMinutes) * 60
        } else {
            usagePollingSeconds = 60
        }

        // Fix zero values from register(defaults:) for integers
        if intervalMinutes == 0 { intervalMinutes = Constants.Defaults.intervalMinutes }
        if maxLogSizeMB == 0 { maxLogSizeMB = Constants.Defaults.maxLogSizeMB }
        if usagePollingSeconds == 0 { usagePollingSeconds = 60 }
        // resetWindowHours == 0 is valid (means "no window tracking"), only fix if never set
        if !defaults.contains(key: Constants.Keys.resetWindowHours) {
            resetWindowHours = Constants.Defaults.resetWindowHours
        }
    }

    /// Formatted start time string
    var windowStartTimeString: String {
        formatTime(hour: windowStartHour, minute: windowStartMinute)
    }

    /// Formatted end time string
    var windowEndTimeString: String {
        formatTime(hour: windowEndHour, minute: windowEndMinute)
    }

    /// Check if current time is within the scheduled window
    var isWithinTimeWindow: Bool {
        if scheduleMode == "allDay" { return true }

        let calendar = Calendar.current
        let now = Date()
        let currentHour = calendar.component(.hour, from: now)
        let currentMinute = calendar.component(.minute, from: now)
        let currentTotal = currentHour * 60 + currentMinute
        let startTotal = windowStartHour * 60 + windowStartMinute
        let endTotal = windowEndHour * 60 + windowEndMinute

        if startTotal <= endTotal {
            return currentTotal >= startTotal && currentTotal < endTotal
        } else {
            // Wraps past midnight
            return currentTotal >= startTotal || currentTotal < endTotal
        }
    }

    private func formatTime(hour: Int, minute: Int) -> String {
        let period = hour >= 12 ? "PM" : "AM"
        let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return String(format: "%d:%02d %@", displayHour, minute, period)
    }

    /// Compute the token reset time: lastPingTime + resetWindowHours
    /// Returns nil if no ping has happened or resetWindowHours == 0
    func tokenResetTime(lastPing: Date?) -> Date? {
        guard resetWindowHours > 0, let lastPing = lastPing else { return nil }
        return lastPing.addingTimeInterval(TimeInterval(resetWindowHours * 3600))
    }

    /// Format reset time for menu bar icon (e.g. "1:00" for 1:00 PM)
    func formatResetTimeShort(lastPing: Date?) -> String? {
        guard let resetTime = tokenResetTime(lastPing: lastPing) else { return nil }
        // If reset time is in the past, show nothing
        if resetTime < Date() { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter.string(from: resetTime)
    }

    private func updateLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                let service = SMAppService.mainApp
                if launchAtLogin {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                print("Launch at login error: \(error)")
            }
        } else {
            // macOS 12: manage LaunchAgent plist directly
            let plistName = "com.pingclaude.app.plist"
            let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents")
            let plistDest = launchAgentsDir.appendingPathComponent(plistName)

            if launchAtLogin {
                // Create LaunchAgents dir if needed
                try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

                // Write plist that launches the app at login
                let plistContent = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
                  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Label</key>
                    <string>com.pingclaude.app</string>
                    <key>ProgramArguments</key>
                    <array>
                        <string>/Applications/PingClaude.app/Contents/MacOS/PingClaude</string>
                    </array>
                    <key>RunAtLoad</key>
                    <true/>
                    <key>KeepAlive</key>
                    <true/>
                    <key>ThrottleInterval</key>
                    <integer>10</integer>
                    <key>StandardErrorPath</key>
                    <string>\(NSHomeDirectory())/Library/Logs/PingClaude/launchd-stderr.log</string>
                </dict>
                </plist>
                """
                try? plistContent.write(to: plistDest, atomically: true, encoding: .utf8)

                // Load agent
                let load = Process()
                load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                load.arguments = ["load", plistDest.path]
                load.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
                try? load.run()
            } else {
                // Unload and remove
                let unload = Process()
                unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                unload.arguments = ["unload", plistDest.path]
                unload.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
                try? unload.run()
                try? FileManager.default.removeItem(at: plistDest)
            }
        }
    }
}

extension UserDefaults {
    func contains(key: String) -> Bool {
        return object(forKey: key) != nil
    }
}
