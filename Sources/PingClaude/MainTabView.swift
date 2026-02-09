import SwiftUI

struct MainTabView: View {
    @ObservedObject var tabSelection: TabSelection
    let settingsStore: SettingsStore
    let pingHistoryStore: PingHistoryStore
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

            ClaudeInfoView(usageService: usageService, settings: settingsStore, velocityTracker: velocityTracker)
                .tabItem {
                    Image(systemName: "chart.bar")
                    Text("Claude Info")
                }
                .tag(MainTab.claudeInfo)
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
