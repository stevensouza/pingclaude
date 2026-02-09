import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var showSessionKey = false
    @State private var showAPIHelp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Claude CLI Section
                GroupBox(label: Text("Claude CLI (Fallback)").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Used for pinging when the Web API credentials below are not configured.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text("Path:")
                                .frame(width: 50, alignment: .trailing)
                            TextField("CLI path", text: $settings.claudePath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse") {
                                browseForCLI()
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                // Ping Command Section
                GroupBox(label: Text("Ping Command").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Prompt:")
                                .frame(width: 50, alignment: .trailing)
                            TextField("Ping prompt", text: $settings.pingPrompt)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("Model:")
                                .frame(width: 50, alignment: .trailing)
                            Picker("", selection: $settings.pingModel) {
                                ForEach(Constants.availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }
                    }
                    .padding(.top, 4)
                }

                // Schedule Section
                GroupBox(label: Text("Schedule").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable Scheduled Pings", isOn: $settings.scheduleEnabled)

                        HStack {
                            Text("Mode:")
                                .frame(width: 50, alignment: .trailing)
                            Picker("", selection: $settings.scheduleMode) {
                                Text("Run all day").tag("allDay")
                                Text("Time window").tag("timeWindow")
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                        }

                        HStack {
                            Text("Interval:")
                                .frame(width: 50, alignment: .trailing)
                            Picker("", selection: $settings.intervalMinutes) {
                                ForEach(Constants.intervalOptions, id: \.minutes) { option in
                                    Text(option.label).tag(option.minutes)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }

                        if settings.scheduleMode == "timeWindow" {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Start:")
                                        .frame(width: 50, alignment: .trailing)
                                    TimePicker(hour: $settings.windowStartHour, minute: $settings.windowStartMinute)
                                }
                                HStack {
                                    Text("End:")
                                        .frame(width: 50, alignment: .trailing)
                                    TimePicker(hour: $settings.windowEndHour, minute: $settings.windowEndMinute)
                                }
                            }
                            .padding(.leading, 4)
                        }

                        Toggle("Ping on app startup", isOn: $settings.pingOnStartup)
                        Toggle("Ping immediately on wake", isOn: $settings.pingOnWake)

                        HStack {
                            Text("Usage poll:")
                                .frame(width: 60, alignment: .trailing)
                            Picker("", selection: $settings.usagePollingSeconds) {
                                Text("15 sec").tag(15)
                                Text("30 sec").tag(30)
                                Text("1 min").tag(60)
                                Text("2 min").tag(120)
                                Text("5 min").tag(300)
                            }
                            .labelsHidden()
                            .frame(width: 100)
                            Text("How often to refresh usage data (free, no tokens)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }

                // Token Window Section
                GroupBox(label: Text("Token Window").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Reset window:")
                                .frame(width: 90, alignment: .trailing)
                            Picker("", selection: $settings.resetWindowHours) {
                                Text("Disabled").tag(0)
                                Text("3 hours").tag(3)
                                Text("4 hours").tag(4)
                                Text("5 hours").tag(5)
                                Text("6 hours").tag(6)
                                Text("8 hours").tag(8)
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }
                        Text("Hours after a ping until tokens roll off. Shown in the menu bar icon. Set to Disabled if Claude removes this limit.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }

                // Usage API Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            Text("Enables API pinging and live usage tracking.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: { showAPIHelp.toggle() }) {
                                Image(systemName: "questionmark.circle")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showAPIHelp, arrowEdge: .trailing) {
                                apiHelpPopover
                            }
                        }

                        HStack {
                            Text("Org ID:")
                                .frame(width: 70, alignment: .trailing)
                            TextField("e.g. a1b2c3d4-e5f6-7890-...", text: $settings.claudeOrgId)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Session Key:")
                                    .frame(width: 70, alignment: .trailing)
                                if showSessionKey {
                                    TextField("sk-ant-sid02-...", text: $settings.claudeSessionKey)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11, design: .monospaced))
                                } else {
                                    SecureField("sk-ant-sid02-...", text: $settings.claudeSessionKey)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11))
                                }
                            }
                            HStack(spacing: 4) {
                                Toggle("Show", isOn: $showSessionKey)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 10))
                                    .padding(.leading, 76)
                                Text("| Auto-refreshes on each API poll.")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }

                        if settings.hasUsageAPIConfig {
                            Text("\u{2713} API ping + usage tracking active")
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Claude Web API").font(.headline)
                }

                // Storage Section
                GroupBox(label: Text("Storage").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Log folder:")
                                .frame(width: 70, alignment: .trailing)
                            TextField("Log folder", text: $settings.logFolder)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse") {
                                browseForFolder()
                            }
                        }
                        HStack {
                            Text("Max size:")
                                .frame(width: 70, alignment: .trailing)
                            Picker("", selection: $settings.maxLogSizeMB) {
                                Text("5 MB").tag(5)
                                Text("10 MB").tag(10)
                                Text("25 MB").tag(25)
                                Text("50 MB").tag(50)
                                Text("100 MB").tag(100)
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }
                    }
                    .padding(.top, 4)
                }

                // Launch at Login
                GroupBox(label: Text("General").font(.headline)) {
                    Toggle("Launch at login", isOn: $settings.launchAtLogin)
                        .padding(.top, 4)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var apiHelpPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How to find your credentials")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("1. Open claude.ai/settings/usage in your browser")
                Text("2. Open DevTools: \u{2318}\u{2325}I (Cmd+Opt+I)")
                Text("3. Click the Network tab, then refresh the page")
                Text("4. Filter by \"usage\" \u{2014} click the request that appears")
            }
            .font(.system(size: 11))

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Org ID")
                    .font(.system(size: 11, weight: .semibold))
                Text("In the Headers tab, the Request URL looks like:")
                    .font(.system(size: 11))
                Text("https://claude.ai/api/organizations/\u{2039}UUID\u{203A}/usage")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.blue.opacity(0.8))
                Text("Copy the UUID between /organizations/ and /usage. It stays constant for your account.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Session Key")
                    .font(.system(size: 11, weight: .semibold))
                Text("In the Cookie header (or response set-cookie), find:")
                    .font(.system(size: 11))
                Text("sessionKey=sk-ant-sid02-\u{2026};")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.blue.opacity(0.8))
                Text("Copy the value after sessionKey= (not the semicolon). It auto-refreshes on each API poll, so once entered it stays valid.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func browseForCLI() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the claude CLI executable"
        if panel.runModal() == .OK, let url = panel.url {
            settings.claudePath = url.path
        }
    }

    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select the log folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.logFolder = url.path
        }
    }
}

struct TimePicker: View {
    @Binding var hour: Int
    @Binding var minute: Int

    private var hours: [Int] { Array(0...23) }
    private var minutes: [Int] { [0, 15, 30, 45] }

    var body: some View {
        HStack(spacing: 4) {
            Picker("", selection: $hour) {
                ForEach(hours, id: \.self) { h in
                    Text(formatHour(h)).tag(h)
                }
            }
            .labelsHidden()
            .frame(width: 90)

            Text(":")

            Picker("", selection: $minute) {
                ForEach(minutes, id: \.self) { m in
                    Text(String(format: "%02d", m)).tag(m)
                }
            }
            .labelsHidden()
            .frame(width: 60)
        }
    }

    private func formatHour(_ h: Int) -> String {
        let period = h >= 12 ? "PM" : "AM"
        let displayHour = h == 0 ? 12 : (h > 12 ? h - 12 : h)
        return "\(displayHour) \(period)"
    }
}
