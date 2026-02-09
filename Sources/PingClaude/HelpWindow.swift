import Cocoa
import SwiftUI

class HelpWindow {
    private var window: NSWindow?

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let helpView = HelpView()
        let hostingView = NSHostingView(rootView: helpView)

        let window = EditableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PingClaude Help"
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 400, height: 400)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

struct HelpView: View {
    private let sections: [(String, String)] = [
        ("Why PingClaude?",
         """
         Claude Code has a rolling 5-hour token usage window. If you start coding \
         at 10 AM and hit the limit at noon, you wait until 3 PM for tokens to free \
         up. By sending small automated pings earlier (e.g., 7 AM), those tokens \
         roll off at noon, effectively resetting your window right when you need it.
         """),
        ("Requirements",
         """
         \u{2022} macOS 12 (Monterey) or later
         \u{2022} Active Claude subscription
         \u{2022} Claude CLI installed (optional \u{2014} only needed if Web API credentials are not configured)
         """),
        ("Build & Install",
         """
         1. Build: Run `make build` in the project directory
         2. Bundle: Run `make bundle` to create the .app
         3. Install: Run `make install` to copy to /Applications
         4. First launch: Right-click the app \u{2192} Open (Gatekeeper bypass)

         Or simply: `make run` to build and launch directly.

         To start at login, enable it in Settings or run:
           ./Scripts/install-launchagent.sh
         """),
        ("Menu Bar Icon",
         """
         The icon in your menu bar shows:
         \u{2022} "CC" \u{2014} App is running (no live usage data configured)
         \u{2022} "CC\u{00B7}44%" \u{2014} Live session utilization from Claude API
         \u{2022} \u{27F3} \u{2014} A ping is in progress
         \u{2022} \u{2713} \u{2014} Last ping succeeded (shown briefly)
         \u{2022} \u{26A0} \u{2014} Last ping failed (shown briefly)

         To see the live percentage, configure the Claude Web API in Settings.
         """),
        ("Menu Items",
         """
         \u{2022} Status \u{2014} Current state (Idle, Pinging, Success, Error)
         \u{2022} Last ping / Next ping \u{2014} Timing information
         \u{2022} Session / Weekly / Extra usage \u{2014} Live metrics (requires Web API)
         \u{2022} Pace \u{2014} Current burn rate (%/hr) and time until rate limit
         \u{2022} Ping Now (\u{2318}P) \u{2014} Manually trigger a ping
         \u{2022} Enable Schedule \u{2014} Toggle automatic pinging
         \u{2022} Settings (\u{2318},) \u{2014} Configure all options
         \u{2022} Ping History (\u{2318}H) \u{2014} View all pings with full responses
         \u{2022} Claude Info (\u{2318}I) \u{2014} Usage dashboard with progress bars
         \u{2022} Help (\u{2318}?) \u{2014} This window
         """),
        ("Settings",
         """
         Claude CLI (Fallback):
         \u{2022} Path \u{2014} Location of the claude executable. Only used when Web API credentials are not configured.

         Ping Command:
         \u{2022} Prompt \u{2014} Text sent to Claude (default: "hi")
         \u{2022} Model \u{2014} Which model to use (haiku recommended for minimal cost)

         Schedule:
         \u{2022} Enable \u{2014} Turn automatic pinging on/off
         \u{2022} Mode \u{2014} "Run all day" or "Time window" (specific hours)
         \u{2022} Interval \u{2014} Time between pings (15 min to 4 hours)
         \u{2022} Ping on startup \u{2014} Fire a ping when the app first launches
         \u{2022} Ping on wake \u{2014} Fire a ping when the computer wakes from sleep
         \u{2022} Usage poll \u{2014} How often to refresh usage data (15 sec to 5 min). Free, no tokens consumed.
         """),
        ("Claude Web API Setup",
         """
         The Claude Web API enables two features:
         1. Pinging via API (no CLI needed)
         2. Live usage tracking (session %, weekly %, monthly spend)

         Usage polling is free \u{2014} it reads your account metrics without \
         consuming any tokens or starting a session. The poll interval is \
         configurable in the Schedule section of Settings (default: every 1 minute, \
         as low as 15 seconds).

         To set up, click the ? icon in the Web API section of Settings \
         for step-by-step instructions on finding your Org ID and Session Key.

         The Org ID never changes. The Session Key auto-refreshes on each poll, \
         so once entered it stays valid as long as the app keeps running.
         """),
        ("Claude Info Tab",
         """
         The Claude Info tab provides a visual dashboard of your usage:
         \u{2022} Session usage with colored progress bar (green/orange/red)
         \u{2022} Usage Pace \u{2014} burn rate (%/hr) for current session, past week, \
         and all time, plus estimated time remaining until rate limit. \
         Color-coded: green (>2h), orange (<2h), red (<1h).
         \u{2022} Weekly usage and per-model breakdowns
         \u{2022} Monthly extra-usage spend
         \u{2022} Reset countdowns and times

         Pace data starts showing after 2+ usage samples are collected \
         (typically within 1\u{2013}2 minutes of launching).

         Data auto-refreshes on the configured poll interval and can be \
         manually refreshed with the Refresh button. Usage polling is free \
         \u{2014} no tokens consumed, no sessions started.

         Requires Claude Web API credentials to be configured in Settings.
         """),
        ("Reset-Triggered Ping",
         """
         When the usage API reports a session reset time and your utilization \
         is above 20%, PingClaude automatically pings at the exact reset \
         moment. This ensures you start the new session window immediately.

         \u{2022} Retries up to 3 times (30s apart) if the session hasn't reset yet
         \u{2022} Skips if a regular scheduled ping is within 2 minutes anyway
         \u{2022} Works independently of the schedule \u{2014} fires as long as usage \
         polling is active
         \u{2022} Logged as "Reset ping" in Ping History
         """),
        ("Ping History",
         """
         A split-view showing every ping with search and date grouping:
         \u{2022} Search bar filters by status, model, response text, etc.
         \u{2022} Records grouped by date (Today, Yesterday, or day name)
         \u{2022} Click any entry to see full details including Claude's response
         \u{2022} Clear button asks for confirmation before deleting all records

         System events (scheduler start/stop, sleep/wake) are also logged.
         """),
        ("Files & Locations",
         """
         \u{2022} App: /Applications/PingClaude.app (after `make install`)
         \u{2022} Logs: ~/Library/Logs/PingClaude/
           \u{2014} pingclaude.log (text event log)
           \u{2014} ping_history.json (full ping records with responses)
           \u{2014} usage_samples.json (velocity tracking data)
         \u{2022} Settings: ~/Library/Preferences/ (via UserDefaults)
         \u{2022} LaunchAgent: ~/Library/LaunchAgents/com.pingclaude.app.plist
         """),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PingClaude")
                    .font(.system(size: 24, weight: .bold))

                Text("Automated Claude pinger for managing your token usage window.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)

                Text("Build \(Constants.buildVersion)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))

                Divider()

                ForEach(sections, id: \.0) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.0)
                            .font(.system(size: 15, weight: .semibold))
                        Text(section.1)
                            .font(.system(size: 13))
                            .foregroundColor(.primary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer().frame(height: 10)
            }
            .padding(24)
        }
        .frame(minWidth: 400, idealWidth: 560, minHeight: 400, idealHeight: 620)
    }
}
