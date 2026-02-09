import Cocoa
import Combine
import SwiftUI

class StatusBarController {
    private var statusItem: NSStatusItem
    private let settingsStore: SettingsStore
    private let pingService: PingService
    private let schedulerService: SchedulerService
    private let pingHistoryStore: PingHistoryStore
    private let logStore: LogStore
    private let usageService: UsageService
    private let velocityTracker: UsageVelocityTracker

    private var mainWindow: MainWindow?
    private var helpWindow: HelpWindow?
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    // Menu items that need updating
    private var statusMenuItem: NSMenuItem!
    private var lastPingMenuItem: NSMenuItem!
    private var nextPingMenuItem: NSMenuItem!
    private var sessionUsageMenuItem: NSMenuItem!
    private var sessionResetMenuItem: NSMenuItem!
    private var weeklyUsageMenuItem: NSMenuItem!
    private var pingResetMenuItem: NSMenuItem!
    private var monthlySpendMenuItem: NSMenuItem!
    private var breakdownMenuItems: [NSMenuItem] = []
    private var usageErrorMenuItem: NSMenuItem!
    private var velocityMenuItem: NSMenuItem!
    private var budgetAdvisorMenuItem: NSMenuItem!
    private var scheduleToggleMenuItem: NSMenuItem!

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    init(settingsStore: SettingsStore,
         pingService: PingService,
         schedulerService: SchedulerService,
         pingHistoryStore: PingHistoryStore,
         logStore: LogStore,
         usageService: UsageService,
         velocityTracker: UsageVelocityTracker) {
        self.settingsStore = settingsStore
        self.pingService = pingService
        self.schedulerService = schedulerService
        self.pingHistoryStore = pingHistoryStore
        self.logStore = logStore
        self.usageService = usageService
        self.velocityTracker = velocityTracker

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        setupMenu()
        setupObservers()
        updateMenuBarIcon()
        startRefreshTimer()
    }

    private func setupMenu() {
        let menu = NSMenu()

        // Status info items (disabled, non-clickable)
        statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        lastPingMenuItem = NSMenuItem(title: "Last ping: Never", action: nil, keyEquivalent: "")
        lastPingMenuItem.isEnabled = false
        menu.addItem(lastPingMenuItem)

        nextPingMenuItem = NSMenuItem(title: "Next ping: --", action: nil, keyEquivalent: "")
        nextPingMenuItem.isEnabled = false
        menu.addItem(nextPingMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Usage section
        sessionUsageMenuItem = NSMenuItem(title: "Session: --", action: nil, keyEquivalent: "")
        sessionUsageMenuItem.isEnabled = false
        menu.addItem(sessionUsageMenuItem)

        sessionResetMenuItem = NSMenuItem(title: "Resets: --", action: nil, keyEquivalent: "")
        sessionResetMenuItem.isEnabled = false
        menu.addItem(sessionResetMenuItem)

        velocityMenuItem = NSMenuItem(title: "Pace: calculating...", action: nil, keyEquivalent: "")
        velocityMenuItem.isEnabled = false
        menu.addItem(velocityMenuItem)

        budgetAdvisorMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        budgetAdvisorMenuItem.isEnabled = false
        budgetAdvisorMenuItem.isHidden = true
        menu.addItem(budgetAdvisorMenuItem)

        weeklyUsageMenuItem = NSMenuItem(title: "Weekly: --", action: nil, keyEquivalent: "")
        weeklyUsageMenuItem.isEnabled = false
        menu.addItem(weeklyUsageMenuItem)

        monthlySpendMenuItem = NSMenuItem(title: "Monthly: --", action: nil, keyEquivalent: "")
        monthlySpendMenuItem.isEnabled = false
        menu.addItem(monthlySpendMenuItem)

        pingResetMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        pingResetMenuItem.isEnabled = false
        pingResetMenuItem.isHidden = true
        menu.addItem(pingResetMenuItem)

        usageErrorMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        usageErrorMenuItem.isEnabled = false
        usageErrorMenuItem.isHidden = true
        menu.addItem(usageErrorMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Ping Now
        let pingNowItem = NSMenuItem(title: "Ping Now", action: #selector(pingNowClicked), keyEquivalent: "p")
        pingNowItem.keyEquivalentModifierMask = .command
        pingNowItem.target = self
        menu.addItem(pingNowItem)

        menu.addItem(NSMenuItem.separator())

        // Schedule toggle
        scheduleToggleMenuItem = NSMenuItem(
            title: "Enable Schedule",
            action: #selector(scheduleToggleClicked),
            keyEquivalent: ""
        )
        scheduleToggleMenuItem.target = self
        scheduleToggleMenuItem.state = settingsStore.scheduleEnabled ? .on : .off
        menu.addItem(scheduleToggleMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(settingsClicked), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Ping History
        let historyItem = NSMenuItem(title: "Ping History...", action: #selector(historyClicked), keyEquivalent: "h")
        historyItem.keyEquivalentModifierMask = .command
        historyItem.target = self
        menu.addItem(historyItem)

        // Claude Info
        let claudeInfoItem = NSMenuItem(title: "Claude Info...", action: #selector(claudeInfoClicked), keyEquivalent: "i")
        claudeInfoItem.keyEquivalentModifierMask = .command
        claudeInfoItem.target = self
        menu.addItem(claudeInfoItem)

        // Help
        let helpItem = NSMenuItem(title: "Help...", action: #selector(helpClicked), keyEquivalent: "?")
        helpItem.keyEquivalentModifierMask = .command
        helpItem.target = self
        menu.addItem(helpItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit PingClaude", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func setupObservers() {
        // Watch ping status changes
        pingService.$currentStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.updateMenuBarIcon()
                self?.updateStatusText(for: status)
            }
            .store(in: &cancellables)

        // Watch last ping time
        pingService.$lastPingTime
            .receive(on: RunLoop.main)
            .sink { [weak self] date in
                guard let self = self else { return }
                if let date = date {
                    self.lastPingMenuItem.title = "Last ping: \(self.timeFormatter.string(from: date))"
                }
                self.updatePingResetLine()
                self.updateMenuBarIcon()
            }
            .store(in: &cancellables)

        // Watch next ping time
        schedulerService.$nextPingTime
            .receive(on: RunLoop.main)
            .sink { [weak self] date in
                guard let self = self else { return }
                if let date = date {
                    self.nextPingMenuItem.title = "Next ping: \(self.timeFormatter.string(from: date))"
                } else {
                    self.nextPingMenuItem.title = "Next ping: --"
                }
            }
            .store(in: &cancellables)

        // Watch schedule enabled state
        settingsStore.$scheduleEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.scheduleToggleMenuItem.state = enabled ? .on : .off
            }
            .store(in: &cancellables)

        // Watch usage data
        usageService.$latestUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] usage in
                self?.updateUsageDisplay(usage)
                self?.updateMenuBarIcon()
            }
            .store(in: &cancellables)

        // Watch usage data from API pings (message_limit event)
        pingService.$lastPingUsageData
            .receive(on: RunLoop.main)
            .compactMap { $0 }
            .sink { [weak self] pingUsage in
                self?.updateUsageFromPing(pingUsage)
            }
            .store(in: &cancellables)

        // Watch usage errors
        usageService.$lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.usageErrorMenuItem.title = "\u{26A0} \(error)"
                    self.usageErrorMenuItem.isHidden = false
                } else {
                    self.usageErrorMenuItem.isHidden = true
                }
            }
            .store(in: &cancellables)

        // Watch velocity tracker
        velocityTracker.$sessionTimeRemaining
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateVelocityDisplay()
                self?.updateMenuBarIcon()
            }
            .store(in: &cancellables)

        // Watch budget advisor
        velocityTracker.$budgetAdvisorMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                guard let self = self else { return }
                if let message = message {
                    self.budgetAdvisorMenuItem.title = "\u{1F4A1} \(message)"
                    self.budgetAdvisorMenuItem.isHidden = false
                } else {
                    self.budgetAdvisorMenuItem.isHidden = true
                }
            }
            .store(in: &cancellables)

        // Watch reset window setting
        settingsStore.$resetWindowHours
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updatePingResetLine()
                self?.updateMenuBarIcon()
            }
            .store(in: &cancellables)
    }

    // MARK: - Display Updates

    private func updateMenuBarIcon() {
        guard let button = statusItem.button else { return }
        let status = pingService.currentStatus

        switch status {
        case .pinging:
            button.title = "\u{27F3}" // ⟳
            return
        case .success:
            button.title = "\u{2713}" // ✓
            return
        case .error:
            button.title = "\u{26A0}" // ⚠
            return
        case .idle:
            break // fall through to usage-based display
        }

        // If we have live usage data, show "CC·44%·O" (with model indicator)
        if let usage = usageService.latestUsage {
            let pct = Int(usage.sessionUtilization)
            if let model = velocityTracker.detectedModel {
                let modelChar = Constants.ModelPricing.shortLabel(model)
                button.title = "CC\u{00B7}\(pct)%\u{00B7}\(modelChar)"
            } else {
                button.title = "CC\u{00B7}\(pct)%"
            }
            return
        }

        // No live data — just show "CC"
        button.title = "CC"
    }

    private func updateUsageDisplay(_ usage: UsageData?) {
        // Remove old breakdown items
        for item in breakdownMenuItems {
            item.menu?.removeItem(item)
        }
        breakdownMenuItems.removeAll()

        guard let usage = usage else {
            sessionUsageMenuItem.title = "Session: --"
            sessionResetMenuItem.title = "Resets: --"
            weeklyUsageMenuItem.title = "Weekly: --"
            monthlySpendMenuItem.title = "Monthly: --"
            return
        }

        sessionUsageMenuItem.title = "Session: \(Int(usage.sessionUtilization))% used"

        if let remaining = usage.sessionResetsInString, let resetTime = usage.sessionResetTimeString {
            sessionResetMenuItem.title = "Resets: in \(remaining) (\(resetTime))"
        } else {
            sessionResetMenuItem.title = "Resets: --"
        }

        if let weekly = usage.weeklyUtilization {
            var weeklyStr = "Weekly: \(Int(weekly))% used"
            if let weeklyReset = usage.weeklyResetsAt {
                let formatter = DateFormatter()
                formatter.dateFormat = "EEE h:mm a"
                weeklyStr += " (resets \(formatter.string(from: weeklyReset)))"
            }
            weeklyUsageMenuItem.title = weeklyStr
        } else {
            weeklyUsageMenuItem.title = "Weekly: --"
        }

        // Extra usage / monthly spend
        if let limit = usage.monthlyLimitCents, let used = usage.monthlyUsedCents, limit > 0 {
            let pct = Int(Double(used) / Double(limit) * 100)
            let usedDollars = String(format: "$%.2f", Double(used) / 100.0)
            let limitDollars = String(format: "$%.2f", Double(limit) / 100.0)
            monthlySpendMenuItem.title = "Extra usage: \(pct)% (\(usedDollars) / \(limitDollars))"
        } else {
            monthlySpendMenuItem.title = "Extra usage: --"
        }

        // Add breakdown items for non-null per-model/special limits
        if let menu = weeklyUsageMenuItem.menu {
            let weeklyIndex = menu.index(of: weeklyUsageMenuItem)
            guard weeklyIndex >= 0 else { return }
            for (i, breakdown) in usage.breakdowns.enumerated() {
                var title = "\(breakdown.label): \(Int(breakdown.utilization))% used"
                if let resetsAt = breakdown.resetsAt {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "EEE h:mm a"
                    title += " (resets \(formatter.string(from: resetsAt)))"
                }
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.insertItem(item, at: weeklyIndex + 1 + i)
                breakdownMenuItems.append(item)
            }
        }
    }

    private func updateVelocityDisplay() {
        let timeStr = velocityTracker.timeRemainingString
        let rateStr = velocityTracker.sessionVelocityString
        let modelTag = velocityTracker.detectedModel.map { " [\($0.capitalized)]" } ?? ""
        if velocityTracker.sessionVelocity == nil {
            velocityMenuItem.title = "Pace: \(rateStr)"
        } else if let vel = velocityTracker.sessionVelocity, vel <= 0 {
            velocityMenuItem.title = "Pace: \(rateStr)"
        } else {
            velocityMenuItem.title = "\u{23F1} \(timeStr) (\(rateStr))\(modelTag)"
        }
    }

    private func updatePingResetLine() {
        // Hide this estimate when live API data is available (Resets: line is better)
        guard usageService.latestUsage == nil,
              settingsStore.resetWindowHours > 0,
              let lastPing = pingService.lastPingTime else {
            pingResetMenuItem.isHidden = true
            return
        }

        let resetTime = lastPing.addingTimeInterval(TimeInterval(settingsStore.resetWindowHours * 3600))
        if resetTime > Date() {
            pingResetMenuItem.title = "Ping cost expires: \(timeFormatter.string(from: resetTime))"
            pingResetMenuItem.isHidden = false
        } else {
            pingResetMenuItem.title = "Ping cost: expired"
            pingResetMenuItem.isHidden = false
        }
    }

    private func updateStatusText(for status: PingStatus) {
        switch status {
        case .idle:
            statusMenuItem.title = "Status: Idle"
        case .pinging:
            statusMenuItem.title = "Status: Pinging..."
        case .success:
            statusMenuItem.title = "Status: Success"
        case .error:
            statusMenuItem.title = "Status: Error"
        }
    }

    /// Periodic refresh for countdown displays
    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.updateUsageDisplay(self.usageService.latestUsage)
            self.updateVelocityDisplay()
            self.updatePingResetLine()
            self.updateMenuBarIcon()
        }
        if let refreshTimer = refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }

    // MARK: - Actions

    @objc private func pingNowClicked() {
        logStore.log("Manual ping triggered")
        pingService.ping { [weak self] result in
            guard let self = self else { return }
            self.pingHistoryStore.addPingResult(result)
            let methodTag = result.method == .api ? "API" : "CLI"
            if result.status == .success {
                self.logStore.log("Manual ping succeeded via \(methodTag) (\(String(format: "%.1f", result.duration))s)")
            } else {
                self.logStore.log("Manual ping failed via \(methodTag): \(result.errorMessage ?? "unknown")")
            }
            // Also refresh full usage data (breakdowns, monthly spend)
            self.usageService.fetchUsage()
        }
    }

    /// Update usage display with data from an API ping's message_limit event
    private func updateUsageFromPing(_ pingUsage: PingUsageData) {
        guard let sessionUtil = pingUsage.sessionUtilization else { return }

        let prev = usageService.latestUsage
        let usage = UsageData(
            sessionUtilization: sessionUtil * 100, // Convert 0-1 to 0-100
            sessionResetsAt: pingUsage.sessionResetsAt.map { Date(timeIntervalSince1970: $0) },
            weeklyUtilization: pingUsage.weeklyUtilization.map { $0 * 100 } ?? prev?.weeklyUtilization,
            weeklyResetsAt: pingUsage.weeklyResetsAt.map { Date(timeIntervalSince1970: $0) } ?? prev?.weeklyResetsAt,
            breakdowns: prev?.breakdowns ?? [],
            monthlyLimitCents: prev?.monthlyLimitCents,
            monthlyUsedCents: prev?.monthlyUsedCents,
            outOfCredits: prev?.outOfCredits,
            fetchedAt: Date()
        )
        usageService.latestUsage = usage
    }

    @objc private func scheduleToggleClicked() {
        settingsStore.scheduleEnabled.toggle()
    }

    @objc private func historyClicked() {
        ensureMainWindow()
        mainWindow?.show(tab: .history)
    }

    @objc private func claudeInfoClicked() {
        ensureMainWindow()
        mainWindow?.show(tab: .claudeInfo)
    }

    @objc private func settingsClicked() {
        ensureMainWindow()
        mainWindow?.show(tab: .settings)
    }

    private func ensureMainWindow() {
        if mainWindow == nil {
            mainWindow = MainWindow(
                settingsStore: settingsStore,
                pingHistoryStore: pingHistoryStore,
                usageService: usageService,
                velocityTracker: velocityTracker
            )
        }
    }

    @objc private func helpClicked() {
        if helpWindow == nil {
            helpWindow = HelpWindow()
        }
        helpWindow?.show()
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
