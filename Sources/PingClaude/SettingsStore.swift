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
    /// Normalizes whatever it is handed, so a pasted `sessionKey=…`, stray quotes, or a trailing
    /// newline can never reach the `Cookie` header. Validation of *server-supplied* values lives in
    /// `applyRefreshedSessionKey` — rejecting invalid values here would make the field uneditable,
    /// since SwiftUI writes this binding on every keystroke.
    @Published var claudeSessionKey: String {
        didSet {
            let sanitized = SessionKeyParser.sanitize(claudeSessionKey)
            if sanitized != claudeSessionKey {
                claudeSessionKey = sanitized
                return
            }
            defaults.set(claudeSessionKey, forKey: Constants.Keys.claudeSessionKey)

            // A different key deserves a fresh attempt — but not when we just rolled back to the
            // backup, or clearing the flag here would let the same rollback repeat forever.
            if claudeSessionKey != oldValue && !isRestoringBackup {
                didRestoreBackup = false
                authFailed = false
            }
        }
    }
    /// The most recent session key that produced an authenticated 200, kept so a bad refresh
    /// can be rolled back instead of locking the user out.
    @Published var lastKnownGoodSessionKey: String {
        didSet { defaults.set(lastKnownGoodSessionKey, forKey: Constants.Keys.claudeSessionKeyBackup) }
    }
    /// True once the credential has been rejected and the rollback below is exhausted — i.e. only
    /// the user can fix it. Drives the menu bar auth-error state. Not persisted.
    @Published private(set) var authFailed: Bool = false
    /// Guards against restoring a backup that has itself already been rejected.
    private var didRestoreBackup = false
    /// True while `noteAuthFailed` is rolling back, so the didSet does not clear the guard above.
    private var isRestoringBackup = false
    /// Set by AppDelegate. Weak because LogStore holds this store.
    weak var logStore: LogStore?
    @Published var claudeOrgId: String {
        didSet { defaults.set(claudeOrgId, forKey: Constants.Keys.claudeOrgId) }
    }
    @Published var usagePollingSeconds: Int {
        didSet { defaults.set(usagePollingSeconds, forKey: Constants.Keys.usagePollingSeconds) }
    }
    /// Whether we have enough config for API-based pinging. Requires a key that actually looks
    /// like a credential — a junk value must not send us into an endless 403 loop.
    var hasUsageAPIConfig: Bool {
        SessionKeyParser.isValid(claudeSessionKey) && !claudeOrgId.isEmpty
    }

    /// Whether a rollback is available for the user to trigger by hand.
    var canRestoreSessionKey: Bool {
        SessionKeyParser.isValid(lastKnownGoodSessionKey)
            && lastKnownGoodSessionKey != claudeSessionKey
    }

    // MARK: - Session Key Lifecycle

    /// The only path a network response may use to write the key. Ignores anything that does not
    /// look like a credential, so a cleared cookie cannot overwrite a working one.
    @discardableResult
    func applyRefreshedSessionKey(_ candidate: String) -> Bool {
        let key = SessionKeyParser.sanitize(candidate)
        guard SessionKeyParser.isValid(key), key != claudeSessionKey else { return false }
        claudeSessionKey = key
        return true
    }

    /// Record that the current key authenticated successfully, and clear any auth-error state.
    func noteAuthSucceeded() {
        if SessionKeyParser.isValid(claudeSessionKey) && claudeSessionKey != lastKnownGoodSessionKey {
            lastKnownGoodSessionKey = claudeSessionKey
        }
        didRestoreBackup = false
        if authFailed {
            authFailed = false
            logStore?.log("Session key accepted again \u{2014} auth restored")
        }
    }

    /// Handle a 401/403. Rolls back to the last known-good key once; if that is unavailable or has
    /// already been tried, surfaces the failure to the user rather than retrying forever.
    /// Returns true when a rollback happened and the caller should retry.
    @discardableResult
    func noteAuthFailed(source: String, statusCode: Int) -> Bool {
        if !didRestoreBackup && canRestoreSessionKey {
            didRestoreBackup = true
            isRestoringBackup = true
            claudeSessionKey = lastKnownGoodSessionKey
            isRestoringBackup = false
            logStore?.log("\(source) HTTP \(statusCode) \u{2014} restored last known-good session key")
            return true
        }

        // The restored key failed too, so it is genuinely expired: stop offering it.
        if didRestoreBackup && !lastKnownGoodSessionKey.isEmpty {
            lastKnownGoodSessionKey = ""
        }

        if !authFailed {
            authFailed = true
            logStore?.log("\(source) auth error: HTTP \(statusCode) \u{2014} session key expired, update it in Settings")
        }
        return false
    }

    /// Manual rollback from the menu bar / Settings.
    @discardableResult
    func restoreLastGoodSessionKey() -> Bool {
        guard canRestoreSessionKey else { return false }
        claudeSessionKey = lastKnownGoodSessionKey
        didRestoreBackup = false
        authFailed = false
        return true
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
            Constants.Keys.claudeSessionKeyBackup: "",
            Constants.Keys.claudeOrgId: "",
            Constants.Keys.usagePollingSeconds: 300
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
        lastKnownGoodSessionKey = defaults.string(forKey: Constants.Keys.claudeSessionKeyBackup) ?? ""
        claudeOrgId = defaults.string(forKey: Constants.Keys.claudeOrgId) ?? ""

        // Migrate legacy usagePollingMinutes → usagePollingSeconds
        if let legacyMinutes = defaults.object(forKey: Constants.Keys.usagePollingMinutes) as? Int, legacyMinutes > 0 {
            usagePollingSeconds = legacyMinutes * 60
            defaults.removeObject(forKey: Constants.Keys.usagePollingMinutes)
        } else {
            usagePollingSeconds = defaults.integer(forKey: Constants.Keys.usagePollingSeconds)
        }

        // Fix zero values from register(defaults:) for integers
        if intervalMinutes == 0 { intervalMinutes = Constants.Defaults.intervalMinutes }
        if maxLogSizeMB == 0 { maxLogSizeMB = Constants.Defaults.maxLogSizeMB }
        if usagePollingSeconds == 0 { usagePollingSeconds = 300 }
        // resetWindowHours == 0 is valid (means "no window tracking"), only fix if never set
        if !defaults.contains(key: Constants.Keys.resetWindowHours) {
            resetWindowHours = Constants.Defaults.resetWindowHours
        }

        // Heal a credential a pre-fix build corrupted with a cookie-clear value (e.g. `""`).
        // Property observers do not run during init, so this cannot be left to the didSet.
        if !claudeSessionKey.isEmpty && !SessionKeyParser.isValid(claudeSessionKey) {
            if SessionKeyParser.isValid(lastKnownGoodSessionKey) {
                claudeSessionKey = lastKnownGoodSessionKey
            } else {
                claudeSessionKey = ""
                // Nothing to fall back on — the user has to paste a fresh key, so say so.
                authFailed = true
            }
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
