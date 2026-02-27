import SwiftUI

// MARK: - LogEntry Model

enum LogLevel {
    case error
    case success
    case warning
    case system
    case info

    var color: Color {
        switch self {
        case .error: return .red
        case .success: return .green
        case .warning: return .orange
        case .system: return .blue
        case .info: return .primary
        }
    }

    var iconName: String {
        switch self {
        case .error: return "xmark.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .system: return "gear"
        case .info: return "info.circle"
        }
    }
}

struct LogEntry: Identifiable {
    let id: Int
    let raw: String
    let timestamp: Date?
    let timeString: String
    let message: String
    let level: LogLevel

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(id: Int, raw: String) {
        self.id = id
        self.raw = raw

        // Parse "[2026-02-27 10:15:30] message text"
        if raw.hasPrefix("["),
           let closeBracket = raw.firstIndex(of: "]") {
            let tsStart = raw.index(after: raw.startIndex)
            let tsString = String(raw[tsStart..<closeBracket])
            self.timestamp = LogEntry.dateFormatter.date(from: tsString)
            if let ts = self.timestamp {
                self.timeString = LogEntry.timeOnlyFormatter.string(from: ts)
            } else {
                self.timeString = tsString
            }
            let msgStart = raw.index(after: closeBracket)
            let msg = String(raw[msgStart...]).trimmingCharacters(in: .whitespaces)
            self.message = msg
        } else {
            self.timestamp = nil
            self.timeString = ""
            self.message = raw
        }

        // Derive level from message keywords
        let lower = self.message.lowercased()
        if lower.contains("failed") || lower.contains("error") || lower.contains("crash") {
            self.level = .error
        } else if lower.contains("succeeded") || lower.contains("success") || lower.contains("confirmed") {
            self.level = .success
        } else if lower.contains("retry") || lower.contains("skipping") || lower.contains("expired")
                    || lower.contains("max retries") || lower.contains("giving up") {
            self.level = .warning
        } else if lower.contains("started") || lower.contains("stopped") || lower.contains("sleep")
                    || lower.contains("woke") || lower.contains("triggered") || lower.contains("scheduled")
                    || lower.contains("firing") {
            self.level = .system
        } else {
            self.level = .info
        }
    }
}

// MARK: - LogEntryGroup

struct LogEntryGroup: Identifiable {
    let id: String
    let label: String
    let entries: [LogEntry]
}

// MARK: - EventLogView

struct EventLogView: View {
    @ObservedObject var logStore: LogStore
    @State private var searchText = ""
    @State private var showClearAlert = false

    private var allEntries: [LogEntry] {
        logStore.entries.enumerated().reversed().map { (index, raw) in
            LogEntry(id: index, raw: raw)
        }
    }

    private var filteredEntries: [LogEntry] {
        guard !searchText.isEmpty else { return allEntries }
        let query = searchText.lowercased()
        return allEntries.filter { entry in
            entry.message.lowercased().contains(query) ||
            entry.timeString.lowercased().contains(query)
        }
    }

    private var groupedEntries: [LogEntryGroup] {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE, MMM d"

        var groups: [String: (label: String, entries: [LogEntry])] = [:]

        for entry in filteredEntries {
            let label: String
            let key: String

            if let ts = entry.timestamp {
                let entryDay = calendar.startOfDay(for: ts)
                if entryDay == today {
                    label = "Today"
                    key = "0_today"
                } else if entryDay == yesterday {
                    label = "Yesterday"
                    key = "1_yesterday"
                } else {
                    label = dayFormatter.string(from: ts)
                    key = String(format: "2_%010d", Int(entryDay.timeIntervalSince1970))
                }
            } else {
                label = "Unknown Date"
                key = "3_unknown"
            }

            if groups[key] == nil {
                groups[key] = (label: label, entries: [])
            }
            groups[key]?.entries.append(entry)
        }

        return groups.sorted { $0.key < $1.key }
            .map { LogEntryGroup(id: $0.key, label: $0.value.label, entries: $0.value.entries) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Event Log")
                    .font(.headline)
                Spacer()
                Text("\(filteredEntries.count) entries")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Button("Clear") {
                    showClearAlert = true
                }
                .disabled(logStore.entries.isEmpty)
            }
            .padding(10)

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("Search log...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()

            // Log entries list
            if filteredEntries.isEmpty {
                VStack {
                    Spacer()
                    if logStore.entries.isEmpty {
                        Text("No log entries yet")
                            .foregroundColor(.secondary)
                    } else {
                        Text("No matching entries")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groupedEntries) { group in
                        Section(header: Text(group.label).font(.system(size: 11, weight: .semibold))) {
                            ForEach(group.entries) { entry in
                                EventLogRowView(entry: entry)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(isPresented: $showClearAlert) {
            Alert(
                title: Text("Clear Event Log"),
                message: Text("This will permanently delete all \(logStore.entries.count) log entries and the log file. This cannot be undone."),
                primaryButton: .destructive(Text("Clear All")) {
                    logStore.clear()
                },
                secondaryButton: .cancel()
            )
        }
    }
}

// MARK: - EventLogRowView

struct EventLogRowView: View {
    let entry: LogEntry

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.level.iconName)
                .font(.system(size: 12))
                .foregroundColor(entry.level.color)
                .frame(width: 16)

            Text(entry.timeString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)

            Text(entry.message)
                .font(.system(size: 12))
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }
}
