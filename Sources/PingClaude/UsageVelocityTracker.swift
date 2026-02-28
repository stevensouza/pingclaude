import Foundation
import Combine

struct ModelSnapshot: Codable {
    let label: String       // "opus", "sonnet"
    let utilization: Double // 0-100 (7-day)
}

struct UsageSample: Codable {
    let timestamp: Date
    let sessionUtilization: Double  // 0-100
    let sessionResetsAt: Date?      // to detect session boundaries
    let modelSnapshots: [ModelSnapshot]
    let detectedModel: String?

    // Backward-compatible decoding: old samples lack modelSnapshots/detectedModel
    init(timestamp: Date, sessionUtilization: Double, sessionResetsAt: Date?,
         modelSnapshots: [ModelSnapshot] = [], detectedModel: String? = nil) {
        self.timestamp = timestamp
        self.sessionUtilization = sessionUtilization
        self.sessionResetsAt = sessionResetsAt
        self.modelSnapshots = modelSnapshots
        self.detectedModel = detectedModel
    }

    enum CodingKeys: String, CodingKey {
        case timestamp, sessionUtilization, sessionResetsAt, modelSnapshots, detectedModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        sessionUtilization = try container.decode(Double.self, forKey: .sessionUtilization)
        sessionResetsAt = try container.decodeIfPresent(Date.self, forKey: .sessionResetsAt)
        modelSnapshots = (try? container.decodeIfPresent([ModelSnapshot].self, forKey: .modelSnapshots)) ?? []
        detectedModel = try? container.decodeIfPresent(String.self, forKey: .detectedModel)
    }
}

class UsageVelocityTracker: ObservableObject {
    @Published var sessionVelocity: Double?      // %/hr, nil if insufficient data
    @Published var weeklyVelocity: Double?       // %/hr
    @Published var allTimeVelocity: Double?      // %/hr
    @Published var sessionTimeRemaining: TimeInterval?  // seconds until 100%
    @Published var sessionSampleCount: Int = 0

    private let settingsStore: SettingsStore
    private let usageService: UsageService
    private var cancellables = Set<AnyCancellable>()
    private var samples: [UsageSample] = []

    private let filePath: String
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(settingsStore: SettingsStore, usageService: UsageService) {
        self.settingsStore = settingsStore
        self.usageService = usageService

        let logFolder = settingsStore.logFolder
        self.filePath = "\(logFolder)/usage_samples.json"

        loadSamples()
        setupObservers()
    }

    // MARK: - Persistence

    private func loadSamples() {
        guard FileManager.default.fileExists(atPath: filePath),
              let data = FileManager.default.contents(atPath: filePath) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([UsageSample].self, from: data) {
            samples = loaded
        }
    }

    private func saveSamples() {
        // Ensure directory exists
        let dir = (filePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(samples) {
            try? data.write(to: URL(fileURLWithPath: filePath))
        }
    }

    // MARK: - Observation

    private func setupObservers() {
        usageService.$latestUsage
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] usage in
                self?.recordSample(usage)
            }
            .store(in: &cancellables)
    }

    private func recordSample(_ usage: UsageData) {
        let sample = UsageSample(
            timestamp: Date(),
            sessionUtilization: usage.sessionUtilization,
            sessionResetsAt: usage.sessionResetsAt
        )

        // Skip duplicate if utilization hasn't changed and last sample was recent (< 30s)
        if let last = samples.last,
           abs(last.sessionUtilization - sample.sessionUtilization) < 0.01,
           sample.timestamp.timeIntervalSince(last.timestamp) < 30 {
            return
        }

        samples.append(sample)
        pruneSamples()
        saveSamples()
        recalculate(currentUtilization: usage.sessionUtilization)
    }

    // MARK: - Pruning

    private func pruneSamples() {
        let now = Date()
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 3600)

        // Partition into recent (last 7 days, keep all) and old (downsample to 1/hr)
        let recent = samples.filter { $0.timestamp >= sevenDaysAgo }
        let old = samples.filter { $0.timestamp < sevenDaysAgo }

        // Downsample old: keep one sample per hour
        var downsampled: [UsageSample] = []
        var lastKeptHour: Int?
        let calendar = Calendar.current
        for sample in old {
            let hour = calendar.component(.hour, from: sample.timestamp)
            let day = calendar.ordinality(of: .day, in: .era, for: sample.timestamp) ?? 0
            let bucket = day * 24 + hour
            if bucket != lastKeptHour {
                downsampled.append(sample)
                lastKeptHour = bucket
            }
        }

        samples = downsampled + recent
    }

    // MARK: - Velocity Calculation

    private func recalculate(currentUtilization: Double) {
        let now = Date()

        let sessionSamples = samplesForCurrentSession()
        sessionSampleCount = sessionSamples.count

        sessionVelocity = computeVelocity(from: sessionSamples)
        weeklyVelocity = computeVelocity(from: samples.filter {
            $0.timestamp >= now.addingTimeInterval(-7 * 24 * 3600)
        })
        allTimeVelocity = computeVelocity(from: samples)

        // Estimate time remaining based on aggregate session velocity
        if let vel = sessionVelocity, vel > 0, currentUtilization < 100 {
            let hoursLeft = (100 - currentUtilization) / vel
            sessionTimeRemaining = hoursLeft * 3600
        } else {
            sessionTimeRemaining = nil
        }
    }

    private func samplesForCurrentSession() -> [UsageSample] {
        guard samples.count >= 2 else { return samples }

        // Walk backwards to find the most recent session reset boundary
        // A reset is detected when sessionResetsAt jumps forward between consecutive samples
        // or when utilization drops significantly (session actually reset)
        var sessionStartIndex = 0
        for i in stride(from: samples.count - 1, through: 1, by: -1) {
            let current = samples[i]
            let previous = samples[i - 1]

            // Detect session reset: utilization dropped significantly
            if previous.sessionUtilization - current.sessionUtilization > 10 {
                sessionStartIndex = i
                break
            }

            // Detect session reset: sessionResetsAt jumped forward
            if let currentReset = current.sessionResetsAt,
               let previousReset = previous.sessionResetsAt,
               currentReset.timeIntervalSince(previousReset) > 3600 {
                sessionStartIndex = i
                break
            }
        }

        return Array(samples[sessionStartIndex...])
    }

    /// Average velocity: total utilization change over total elapsed time.
    /// Returns %/hr, or nil if insufficient data.
    private func computeVelocity(from windowSamples: [UsageSample]) -> Double? {
        guard windowSamples.count >= 2,
              let first = windowSamples.first,
              let last = windowSamples.last else { return nil }

        let totalSeconds = last.timestamp.timeIntervalSince(first.timestamp)
        guard totalSeconds > 60 else { return nil }  // need >1 min of data

        let totalDelta = last.sessionUtilization - first.sessionUtilization
        guard totalDelta > 0 else { return nil }

        let totalHours = totalSeconds / 3600
        return totalDelta / totalHours
    }

    // MARK: - Formatting Helpers

    var sessionVelocityString: String {
        guard let vel = sessionVelocity else { return "calculating..." }
        if vel <= 0 { return "not actively consuming" }
        return String(format: "%.1f%%/hr", vel)
    }

    var weeklyVelocityString: String {
        guard let vel = weeklyVelocity else { return "\u{2014}" }
        if vel <= 0 { return "flat" }
        return String(format: "%.1f%%/hr", vel)
    }

    var allTimeVelocityString: String {
        guard let vel = allTimeVelocity else { return "\u{2014}" }
        if vel <= 0 { return "flat" }
        return String(format: "%.1f%%/hr", vel)
    }

    var timeRemainingString: String {
        guard let remaining = sessionTimeRemaining else {
            if let vel = sessionVelocity, vel <= 0 {
                return "not actively consuming"
            }
            return "calculating..."
        }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 {
            return "~\(hours)h \(minutes)m left"
        }
        return "~\(minutes)m left"
    }

    var timeRemainingHours: Double? {
        guard let remaining = sessionTimeRemaining else { return nil }
        return remaining / 3600
    }

}
