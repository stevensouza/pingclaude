import SwiftUI

struct RecordGroup: Identifiable {
    let id: String // date label
    let label: String
    let records: [PingRecord]
}

struct PingHistoryView: View {
    @ObservedObject var store: PingHistoryStore
    @State private var selectedRecordID: UUID?
    @State private var showClearAlert = false
    @State private var searchText = ""

    private var filteredRecords: [PingRecord] {
        guard !searchText.isEmpty else { return store.records }
        let query = searchText.lowercased()
        return store.records.filter { record in
            record.briefDescription.lowercased().contains(query) ||
            record.response.lowercased().contains(query) ||
            (record.errorMessage?.lowercased().contains(query) ?? false) ||
            (record.model?.lowercased().contains(query) ?? false) ||
            record.status.lowercased().contains(query)
        }
    }

    private var groupedRecords: [RecordGroup] {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE, MMM d"

        var groups: [String: (label: String, sortDate: Date, records: [PingRecord])] = [:]

        for record in filteredRecords {
            let recordDay = calendar.startOfDay(for: record.timestamp)
            let label: String
            let key: String

            if recordDay == today {
                label = "Today"
                key = "0_today"
            } else if recordDay == yesterday {
                label = "Yesterday"
                key = "1_yesterday"
            } else {
                label = dayFormatter.string(from: record.timestamp)
                // Sort key ensures chronological ordering (newest first)
                let dayKey = String(format: "2_%010d", Int(recordDay.timeIntervalSince1970))
                key = dayKey
            }

            if groups[key] == nil {
                groups[key] = (label: label, sortDate: recordDay, records: [])
            }
            groups[key]?.records.append(record)
        }

        return groups.sorted { $0.key < $1.key }
            .map { RecordGroup(id: $0.key, label: $0.value.label, records: $0.value.records) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Ping History")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    showClearAlert = true
                }
                .disabled(store.records.isEmpty)
            }
            .padding(10)

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("Search history...", text: $searchText)
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

            // Split view: list + detail
            HSplitView {
                // Left pane: list with date sections
                List(selection: $selectedRecordID) {
                    ForEach(groupedRecords) { group in
                        Section(header: Text(group.label).font(.system(size: 11, weight: .semibold))) {
                            ForEach(group.records) { record in
                                PingHistoryRowView(record: record)
                                    .tag(record.id)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .frame(minWidth: 200, idealWidth: 260)

                // Right pane: detail
                if let selectedID = selectedRecordID,
                   let record = store.records.first(where: { $0.id == selectedID }) {
                    PingDetailView(record: record)
                        .frame(minWidth: 300, idealWidth: 400)
                } else {
                    VStack {
                        Spacer()
                        Text("Select a ping to view details")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(minWidth: 300, idealWidth: 400)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(isPresented: $showClearAlert) {
            Alert(
                title: Text("Clear Ping History"),
                message: Text("This will permanently delete all \(store.records.count) records. This cannot be undone."),
                primaryButton: .destructive(Text("Clear All")) {
                    store.clear()
                    selectedRecordID = nil
                },
                secondaryButton: .cancel()
            )
        }
        .onAppear {
            if selectedRecordID == nil, let first = store.records.first {
                selectedRecordID = first.id
            }
        }
        .onReceive(store.$records) { records in
            // Auto-select newest record when a new ping arrives
            if let first = records.first, selectedRecordID != first.id {
                // Only auto-select if the first record is truly new (not just a reload)
                if selectedRecordID == nil || !records.contains(where: { $0.id == selectedRecordID }) {
                    selectedRecordID = first.id
                }
            }
        }
    }
}

struct PingHistoryRowView: View {
    let record: PingRecord

    var body: some View {
        HStack(spacing: 6) {
            Text(record.statusIcon)
                .font(.system(size: 14))
                .foregroundColor(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.formattedTime)
                    .font(.system(size: 12, weight: .medium))
                Text(record.briefDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .opacity(record.isSystemEvent ? 0.7 : 1.0)
    }

    private var iconColor: Color {
        switch record.status {
        case "success": return .green
        case "error": return .orange
        case "system": return .blue
        default: return .secondary
        }
    }
}

struct PingDetailView: View {
    let record: PingRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if record.isSystemEvent {
                    systemEventDetail
                } else {
                    pingDetail
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var pingDetail: some View {
        Text("Ping at \(record.formattedDate)")
            .font(.headline)

        // Status & Method row
        HStack(spacing: 16) {
            LabeledField(label: "Status", value: record.status == "success" ? "Success" : "Error")
            LabeledField(label: "Method", value: (record.method ?? "cli").uppercased())
            LabeledField(label: "Duration", value: String(format: "%.1fs", record.duration))
        }

        if let model = record.model, !model.isEmpty {
            LabeledField(label: "Model", value: model)
        }

        LabeledField(label: "Command", value: record.command)

        if let url = record.apiURL, !url.isEmpty {
            LabeledField(label: "API Endpoint", value: url)
        }

        if let error = record.errorMessage, !error.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Error")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(error)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.red)
                    .textSelection(.enabled)
            }
        }

        // Usage snapshot from this ping
        if record.usageSessionPct != nil || record.usageWeeklyPct != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage at Time of Ping")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    if let sessionPct = record.usageSessionPct {
                        HStack(spacing: 4) {
                            Text("Session: \(Int(sessionPct))%")
                                .font(.system(size: 12, design: .monospaced))
                            if let resets = record.usageSessionResets {
                                Text("(resets \(resets))")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    if let weeklyPct = record.usageWeeklyPct {
                        HStack(spacing: 4) {
                            Text("Weekly: \(Int(weeklyPct))%")
                                .font(.system(size: 12, design: .monospaced))
                            if let resets = record.usageWeeklyResets {
                                Text("(resets \(resets))")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(4)
            }
        }

        if !record.response.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Response")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                Text(record.response)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
            }
        }
    }

    @ViewBuilder
    private var systemEventDetail: some View {
        Text("System Event")
            .font(.headline)
        LabeledField(label: "Time", value: record.formattedDate)
        LabeledField(label: "Event", value: record.response)
    }
}

struct LabeledField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
