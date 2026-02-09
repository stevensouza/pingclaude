import Foundation
import Combine
import Cocoa

class SchedulerService: ObservableObject {
    private let settingsStore: SettingsStore
    private let pingService: PingService
    private let pingHistoryStore: PingHistoryStore
    private let logStore: LogStore
    private let usageService: UsageService

    @Published var nextPingTime: Date?
    @Published var isRunning = false

    private var timer: Timer?
    private var resetPingTimer: Timer?
    private var lastScheduledResetTime: Date?  // avoid re-scheduling same reset
    private var resetPingRetryCount = 0
    private var preResetUtilization: Double = 0  // utilization when we scheduled the reset ping
    private var cancellables = Set<AnyCancellable>()

    private static let resetPingMinUtilization: Double = 20  // only fire if usage was >20%
    private static let resetPingCoalesceWindow: TimeInterval = 120  // 2 minutes
    private static let resetPingMaxRetries = 3
    private static let resetPingRetryDelay: TimeInterval = 30

    init(settingsStore: SettingsStore,
         pingService: PingService,
         pingHistoryStore: PingHistoryStore,
         logStore: LogStore,
         usageService: UsageService) {
        self.settingsStore = settingsStore
        self.pingService = pingService
        self.pingHistoryStore = pingHistoryStore
        self.logStore = logStore
        self.usageService = usageService

        setupSleepWakeObservers()
        setupSettingsObservers()
        setupResetPingObserver()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        logStore.log("Scheduler started")
        pingHistoryStore.addSystemEvent("Scheduler started")
        scheduleNextPing()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        nextPingTime = nil
        logStore.log("Scheduler stopped")
        pingHistoryStore.addSystemEvent("Scheduler stopped")
    }

    func reschedule() {
        timer?.invalidate()
        timer = nil

        guard isRunning else {
            nextPingTime = nil
            return
        }

        scheduleNextPing()
    }

    private func scheduleNextPing() {
        let intervalSeconds = TimeInterval(settingsStore.intervalMinutes * 60)

        // Calculate next fire time
        let fireDate: Date
        if settingsStore.scheduleMode == "timeWindow" && !settingsStore.isWithinTimeWindow {
            // Schedule for the start of the next window
            fireDate = nextWindowStart()
            logStore.log("Outside time window. Next ping at \(formatDate(fireDate))")
        } else {
            fireDate = Date().addingTimeInterval(intervalSeconds)
        }

        nextPingTime = fireDate
        let delay = fireDate.timeIntervalSinceNow

        // Use a non-repeating timer
        timer = Timer.scheduledTimer(withTimeInterval: max(delay, 1), repeats: false) { [weak self] _ in
            self?.firePing()
        }
        // Make sure it fires even when menus are open
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func firePing() {
        // Check if we're within the time window (for timeWindow mode)
        if settingsStore.scheduleMode == "timeWindow" && !settingsStore.isWithinTimeWindow {
            logStore.log("Skipping ping: outside time window")
            reschedule()
            return
        }

        logStore.log("Scheduled ping firing")

        pingService.ping { [weak self] result in
            guard let self = self else { return }

            self.pingHistoryStore.addPingResult(result)

            if result.status == .success {
                self.logStore.log("Ping succeeded (\(String(format: "%.1f", result.duration))s)")
            } else {
                self.logStore.log("Ping failed: \(result.errorMessage ?? "unknown error")")
            }

            // Schedule the next ping
            self.reschedule()
        }
    }

    private func nextWindowStart() -> Date {
        let calendar = Calendar.current
        let now = Date()

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = settingsStore.windowStartHour
        components.minute = settingsStore.windowStartMinute
        components.second = 0

        guard let todayStart = calendar.date(from: components) else {
            return now.addingTimeInterval(3600) // Fallback: 1 hour
        }

        if todayStart > now {
            return todayStart
        } else {
            // Tomorrow
            return calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now.addingTimeInterval(3600)
        }
    }

    private func setupSleepWakeObservers() {
        let workspace = NSWorkspace.shared

        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSleep()
        }

        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    private func setupSettingsObservers() {
        // React to schedule enable/disable
        settingsStore.$scheduleEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                if enabled {
                    self?.start()
                } else {
                    self?.stop()
                }
            }
            .store(in: &cancellables)

        // React to interval or mode changes
        Publishers.CombineLatest3(
            settingsStore.$intervalMinutes,
            settingsStore.$scheduleMode,
            settingsStore.$scheduleEnabled
        )
        .dropFirst()
        .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
        .sink { [weak self] _, _, enabled in
            if enabled {
                self?.reschedule()
            }
        }
        .store(in: &cancellables)

        // React to time window changes
        Publishers.CombineLatest4(
            settingsStore.$windowStartHour,
            settingsStore.$windowStartMinute,
            settingsStore.$windowEndHour,
            settingsStore.$windowEndMinute
        )
        .dropFirst()
        .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
        .sink { [weak self] _, _, _, _ in
            if self?.settingsStore.scheduleEnabled == true {
                self?.reschedule()
            }
        }
        .store(in: &cancellables)
    }

    private func handleSleep() {
        logStore.log("System going to sleep")
        pingHistoryStore.addSystemEvent("System sleep")
        timer?.invalidate()
        timer = nil
    }

    private func handleWake() {
        logStore.log("System woke up")
        pingHistoryStore.addSystemEvent("System wake")

        // Wait a few seconds for network to come up, then ping immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.wakeDelaySeconds) { [weak self] in
            guard let self = self else { return }

            if self.settingsStore.pingOnWake {
                // Always ping on wake regardless of schedule
                self.logStore.log("Wake ping firing")
                self.pingService.ping { [weak self] result in
                    guard let self = self else { return }
                    self.pingHistoryStore.addPingResult(result)
                    if result.status == .success {
                        self.logStore.log("Wake ping succeeded (\(String(format: "%.1f", result.duration))s)")
                    } else {
                        self.logStore.log("Wake ping failed: \(result.errorMessage ?? "unknown")")
                    }
                    // Then reschedule normally if scheduler is running
                    if self.isRunning {
                        self.reschedule()
                    }
                }
            } else if self.isRunning {
                self.reschedule()
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    // MARK: - Reset-Triggered Ping

    private func setupResetPingObserver() {
        usageService.$latestUsage
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] usage in
                self?.scheduleResetPingIfNeeded(usage)
            }
            .store(in: &cancellables)
    }

    private func scheduleResetPingIfNeeded(_ usage: UsageData) {
        guard let resetsAt = usage.sessionResetsAt else { return }

        // Don't re-schedule for the same reset time
        if let last = lastScheduledResetTime,
           abs(resetsAt.timeIntervalSince(last)) < 60 {
            return
        }

        // Only schedule if utilization is meaningful (>20%)
        guard usage.sessionUtilization > Self.resetPingMinUtilization else { return }

        let delay = resetsAt.timeIntervalSinceNow
        guard delay > 0 else { return }  // reset already passed

        // Cancel any previous reset ping timer
        resetPingTimer?.invalidate()

        lastScheduledResetTime = resetsAt
        preResetUtilization = usage.sessionUtilization
        resetPingRetryCount = 0

        logStore.log("Reset ping scheduled for \(formatDate(resetsAt)) (usage at \(Int(usage.sessionUtilization))%)")

        resetPingTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.fireResetPing()
        }
        if let resetPingTimer = resetPingTimer {
            RunLoop.main.add(resetPingTimer, forMode: .common)
        }
    }

    private func fireResetPing() {
        // Coalesce: if next scheduled ping is within 2 minutes, skip
        if let nextPing = nextPingTime,
           abs(nextPing.timeIntervalSinceNow) < Self.resetPingCoalesceWindow {
            logStore.log("Reset ping skipped — scheduled ping is within 2 min")
            return
        }

        logStore.log("Reset ping firing (attempt \(resetPingRetryCount + 1))")

        // Refresh usage data first to get fresh numbers
        usageService.fetchUsage()

        pingService.ping { [weak self] result in
            guard let self = self else { return }
            self.pingHistoryStore.addPingResult(result)

            let methodTag = result.method == .api ? "API" : "CLI"
            if result.status == .success {
                self.logStore.log("Reset ping succeeded via \(methodTag) (\(String(format: "%.1f", result.duration))s)")
            } else {
                self.logStore.log("Reset ping failed via \(methodTag): \(result.errorMessage ?? "unknown")")
            }

            // Check if session actually reset — usage should have dropped
            // Wait a moment for the usage fetch to complete, then check
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.checkResetAndRetryIfNeeded()
            }
        }
    }

    private func checkResetAndRetryIfNeeded() {
        guard let usage = usageService.latestUsage else { return }

        // If utilization dropped significantly, the reset happened
        if usage.sessionUtilization < preResetUtilization * 0.5 ||
           usage.sessionUtilization < Self.resetPingMinUtilization {
            logStore.log("Session reset confirmed (now at \(Int(usage.sessionUtilization))%)")
            return
        }

        // Still high — retry if we haven't exceeded max retries
        resetPingRetryCount += 1
        if resetPingRetryCount >= Self.resetPingMaxRetries {
            logStore.log("Reset ping: max retries reached, session may not have reset yet (\(Int(usage.sessionUtilization))%)")
            return
        }

        logStore.log("Session hasn't reset yet (\(Int(usage.sessionUtilization))%), retrying in \(Int(Self.resetPingRetryDelay))s...")

        resetPingTimer = Timer.scheduledTimer(withTimeInterval: Self.resetPingRetryDelay, repeats: false) { [weak self] _ in
            self?.fireResetPing()
        }
        if let resetPingTimer = resetPingTimer {
            RunLoop.main.add(resetPingTimer, forMode: .common)
        }
    }

    deinit {
        timer?.invalidate()
        resetPingTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
