import Foundation
import Combine

class LogStore: ObservableObject {
    private let settingsStore: SettingsStore
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    @Published var entries: [String] = []

    private var logFileURL: URL {
        let folder = settingsStore.logFolder
        return URL(fileURLWithPath: folder).appendingPathComponent("pingclaude.log")
    }

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        ensureLogDirectory()
        loadRecentEntries()
    }

    func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"

        DispatchQueue.main.async {
            self.entries.append(line)
            // Keep only last 500 entries in memory
            if self.entries.count > 500 {
                self.entries.removeFirst(self.entries.count - 500)
            }
        }

        // Append to file
        appendToFile(line)
        checkAndPruneLogSize()
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: logFileURL)
    }

    private func ensureLogDirectory() {
        let folder = settingsStore.logFolder
        try? FileManager.default.createDirectory(
            atPath: folder,
            withIntermediateDirectories: true
        )
    }

    private func appendToFile(_ line: String) {
        ensureLogDirectory()
        let url = logFileURL

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let data = (line + "\n").data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
        } else {
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func loadRecentEntries() {
        guard FileManager.default.fileExists(atPath: logFileURL.path),
              let content = try? String(contentsOf: logFileURL, encoding: .utf8) else {
            return
        }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        // Load last 200 entries
        entries = Array(lines.suffix(200))
    }

    func checkAndPruneLogSize() {
        let maxBytes = settingsStore.maxLogSizeMB * 1024 * 1024
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let fileSize = attrs[.size] as? Int,
              fileSize > maxBytes else {
            return
        }

        // Prune: keep only the last half of the file
        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n")
        let keepLines = Array(lines.suffix(lines.count / 2))
        try? keepLines.joined(separator: "\n").write(to: logFileURL, atomically: true, encoding: .utf8)
    }
}
