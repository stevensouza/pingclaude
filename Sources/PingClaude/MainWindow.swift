import Cocoa
import SwiftUI

enum MainTab: Int {
    case settings = 0
    case history = 1
    case claudeInfo = 2
}

class TabSelection: ObservableObject {
    @Published var selectedTab: MainTab = .settings
}

class MainWindow {
    private var window: NSWindow?
    private let settingsStore: SettingsStore
    private let pingHistoryStore: PingHistoryStore
    private let usageService: UsageService
    private let velocityTracker: UsageVelocityTracker
    private let tabSelection = TabSelection()

    init(settingsStore: SettingsStore, pingHistoryStore: PingHistoryStore, usageService: UsageService, velocityTracker: UsageVelocityTracker) {
        self.settingsStore = settingsStore
        self.pingHistoryStore = pingHistoryStore
        self.usageService = usageService
        self.velocityTracker = velocityTracker
    }

    func show(tab: MainTab) {
        tabSelection.selectedTab = tab

        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let mainView = MainTabView(
            tabSelection: tabSelection,
            settingsStore: settingsStore,
            pingHistoryStore: pingHistoryStore,
            usageService: usageService,
            velocityTracker: velocityTracker
        )
        let hostingView = NSHostingView(rootView: mainView)

        let window = EditableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PingClaude"
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 500, height: 400)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
