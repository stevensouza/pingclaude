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
        schedulerService = SchedulerService(
            settingsStore: settingsStore,
            pingService: pingService,
            pingHistoryStore: pingHistoryStore,
            logStore: logStore
        )
        usageService = UsageService(settingsStore: settingsStore)

        // Initialize status bar
        statusBarController = StatusBarController(
            settingsStore: settingsStore,
            pingService: pingService,
            schedulerService: schedulerService,
            pingHistoryStore: pingHistoryStore,
            logStore: logStore,
            usageService: usageService
        )

        logStore.log("PingClaude started")

        // Ping on startup if enabled
        if settingsStore.pingOnStartup {
            logStore.log("Startup ping firing")
            pingService.ping { [weak self] result in
                guard let self = self else { return }
                self.pingHistoryStore.addPingResult(result)
                if result.status == .success {
                    self.logStore.log("Startup ping succeeded (\(String(format: "%.1f", result.duration))s)")
                } else {
                    self.logStore.log("Startup ping failed: \(result.errorMessage ?? "unknown")")
                }
            }
        }

        // Start scheduler if enabled
        if settingsStore.scheduleEnabled {
            schedulerService.start()
        }

        // Start usage polling if configured
        if settingsStore.hasUsageAPIConfig {
            usageService.startPolling()
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
