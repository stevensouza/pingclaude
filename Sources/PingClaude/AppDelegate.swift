import Cocoa
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var settingsStore: SettingsStore!
    private var logStore: LogStore!
    private var pingHistoryStore: PingHistoryStore!
    private var pingService: PingService!
    private var schedulerService: SchedulerService!
    private var usageService: UsageService!
    private var velocityTracker: UsageVelocityTracker!
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent App Nap so timers fire reliably
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "PingClaude needs timely ping scheduling"
        )

        // Initialize services
        settingsStore = SettingsStore()
        logStore = LogStore(settingsStore: settingsStore)
        pingHistoryStore = PingHistoryStore(settingsStore: settingsStore)
        pingService = PingService(settingsStore: settingsStore)
        usageService = UsageService(settingsStore: settingsStore)
        schedulerService = SchedulerService(
            settingsStore: settingsStore,
            pingService: pingService,
            pingHistoryStore: pingHistoryStore,
            logStore: logStore,
            usageService: usageService
        )
        velocityTracker = UsageVelocityTracker(settingsStore: settingsStore, usageService: usageService)

        // Initialize status bar
        statusBarController = StatusBarController(
            settingsStore: settingsStore,
            pingService: pingService,
            schedulerService: schedulerService,
            pingHistoryStore: pingHistoryStore,
            logStore: logStore,
            usageService: usageService,
            velocityTracker: velocityTracker
        )

        // Check if we restarted after a crash
        checkCrashRecovery()

        logStore.log("PingClaude started")

        // Ping on startup with automatic retry (handled by SchedulerService)
        schedulerService.handleStartup()

        // Start scheduler if enabled
        if settingsStore.scheduleEnabled {
            schedulerService.start()
        }

        // Start usage polling if configured
        if settingsStore.hasUsageAPIConfig {
            usageService.startPolling()
        }
    }

    private func checkCrashRecovery() {
        let crashLogPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PingClaude/crash.log")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: crashLogPath.path),
              let modDate = attrs[.modificationDate] as? Date else { return }
        if Date().timeIntervalSince(modDate) < 60 {
            logStore.log("Restarted after crash — see ~/Library/Logs/PingClaude/crash.log for details")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        schedulerService?.stop()
        usageService?.stopPolling()
        logStore?.log("PingClaude stopped")
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
    }
}
