import Foundation
import Combine
import Cocoa

class SchedulerService: ObservableObject {
    private let settingsStore: SettingsStore
    private let pingService: PingService
    private let pingHistoryStore: PingHistoryStore
    private let logStore: LogStore

    @Published var nextPingTime: Date?
    @Published var isRunning = false

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(settingsStore: SettingsStore,
         pingService: PingService,
         pingHistoryStore: PingHistoryStore,
         logStore: LogStore) {
        self.settingsStore = settingsStore
        self.pingService = pingService
        self.pingHistoryStore = pingHistoryStore
        self.logStore = logStore

        setupSleepWakeObservers()
        setupSettingsObservers()
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

    deinit {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
