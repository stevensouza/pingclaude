import Foundation
import Combine

struct PingRecord: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let status: String // "success" or "error"
    let duration: TimeInterval
    let command: String
    let response: String
    let errorMessage: String?
    let isSystemEvent: Bool
    let method: String? // "api" or "cli" — nil for old records and system events
    let apiURL: String? // API endpoint URL (no sensitive data)
    let model: String? // Full model name used
    let usageSessionPct: Double? // Session usage % at time of ping (0-100)
    let usageWeeklyPct: Double? // Weekly usage % at time of ping (0-100)
    let usageSessionResets: String? // When session resets (formatted)
    let usageWeeklyResets: String? // When weekly resets (formatted)

    init(from result: PingResult) {
        self.id = result.id
        self.timestamp = result.timestamp
        self.status = result.status.rawValue
        self.duration = result.duration
        self.command = result.command
        self.response = result.response
        self.errorMessage = result.errorMessage
        self.isSystemEvent = false
        self.method = result.method.rawValue
        self.apiURL = result.apiURL
        self.model = result.model

        // Convert usage data from 0-1 scale to 0-100
        if let usage = result.usageFromPing {
            self.usageSessionPct = usage.sessionUtilization.map { $0 * 100 }
            self.usageWeeklyPct = usage.weeklyUtilization.map { $0 * 100 }
            self.usageSessionResets = usage.sessionResetsAt.map { PingRecord.formatUnixTimestamp($0) }
            self.usageWeeklyResets = usage.weeklyResetsAt.map { PingRecord.formatUnixTimestamp($0) }
        } else {
            self.usageSessionPct = nil
            self.usageWeeklyPct = nil
            self.usageSessionResets = nil
            self.usageWeeklyResets = nil
        }
    }

    init(systemEvent message: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.status = "system"
        self.duration = 0
        self.command = ""
        self.response = message
        self.errorMessage = nil
        self.isSystemEvent = true
        self.method = nil
        self.apiURL = nil
        self.model = nil
        self.usageSessionPct = nil
        self.usageWeeklyPct = nil
        self.usageSessionResets = nil
        self.usageWeeklyResets = nil
    }

    private static func formatUnixTimestamp(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let displayFmt = DateFormatter()
        displayFmt.dateFormat = "MMM d, h:mm a"
        return displayFmt.string(from: date)
    }

    var statusIcon: String {
        switch status {
        case "success": return "\u{2713}" // ✓
        case "error": return "\u{26A0}" // ⚠
        case "system": return "\u{2139}" // ℹ
        default: return "?"
        }
    }

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        return formatter.string(from: timestamp)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm:ss a"
        return formatter.string(from: timestamp)
    }

    var briefDescription: String {
        if isSystemEvent { return response }
        let methodTag = method == "api" ? "API" : "CLI"
        let result = status == "success" ? "OK" : (errorMessage ?? "Error")
        return "[\(methodTag)] \(result)"
    }
}

class PingHistoryStore: ObservableObject {
    private let settingsStore: SettingsStore
    @Published var records: [PingRecord] = []

    private var historyFileURL: URL {
        let folder = settingsStore.logFolder
        return URL(fileURLWithPath: folder).appendingPathComponent("ping_history.json")
    }

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        ensureDirectory()
        loadRecords()
    }

    func addPingResult(_ result: PingResult) {
        let record = PingRecord(from: result)
        DispatchQueue.main.async {
            self.records.insert(record, at: 0)
            self.saveRecords()
            self.pruneIfNeeded()
        }
    }

    func addSystemEvent(_ message: String) {
        let record = PingRecord(systemEvent: message)
        DispatchQueue.main.async {
            self.records.insert(record, at: 0)
            self.saveRecords()
        }
    }

    func clear() {
        records.removeAll()
        try? FileManager.default.removeItem(at: historyFileURL)
    }

    private func ensureDirectory() {
        let folder = settingsStore.logFolder
        try? FileManager.default.createDirectory(
            atPath: folder,
            withIntermediateDirectories: true
        )
    }

    private func loadRecords() {
        guard FileManager.default.fileExists(atPath: historyFileURL.path),
              let data = try? Data(contentsOf: historyFileURL) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([PingRecord].self, from: data) {
            records = loaded
        }
    }

    private func saveRecords() {
        ensureDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        if let data = try? encoder.encode(records) {
            try? data.write(to: historyFileURL, options: .atomic)
        }
    }

    func pruneIfNeeded() {
        let maxBytes = settingsStore.maxLogSizeMB * 1024 * 1024

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: historyFileURL.path),
              let fileSize = attrs[.size] as? Int,
              fileSize > maxBytes else {
            return
        }

        // Remove oldest half of records
        let keepCount = records.count / 2
        if keepCount > 0 {
            records = Array(records.prefix(keepCount))
            saveRecords()
        }
    }
}
