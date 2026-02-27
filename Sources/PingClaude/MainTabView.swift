import SwiftUI

struct MainTabView: View {
    @ObservedObject var tabSelection: TabSelection
    let settingsStore: SettingsStore
    let pingHistoryStore: PingHistoryStore
    let logStore: LogStore
    let usageService: UsageService
    let velocityTracker: UsageVelocityTracker

    var body: some View {
        TabView(selection: $tabSelection.selectedTab) {
            SettingsView(settings: settingsStore)
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
                .tag(MainTab.settings)

            PingHistoryView(store: pingHistoryStore)
                .tabItem {
                    Image(systemName: "clock")
                    Text("History")
                }
                .tag(MainTab.history)

            EventLogView(logStore: logStore)
                .tabItem {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Event Log")
                }
                .tag(MainTab.eventLog)

            ClaudeInfoView(usageService: usageService, settings: settingsStore, velocityTracker: velocityTracker, tabSelection: tabSelection)
                .tabItem {
                    Image(systemName: "chart.bar")
                    Text("Claude Info")
                }
                .tag(MainTab.claudeInfo)
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
