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

/// Per-model time estimate for display in SwiftUI
struct ModelTimeEstimate: Identifiable {
    let model: String
    let timeRemaining: TimeInterval?  // seconds, nil if can't estimate
    let isCurrent: Bool

    var id: String { model }

    var displayString: String {
        guard let remaining = timeRemaining else { return "—" }
        if remaining <= 0 { return "exhausted" }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 {
            return "~\(hours)h \(minutes)m"
        }
        return "~\(minutes)m"
    }

    var shortDisplayString: String {
        guard let remaining = timeRemaining else { return "—" }
        if remaining <= 0 { return "0m" }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 {
            return "~\(hours)h\(minutes)m"
        }
        return "~\(minutes)m"
    }
}

class UsageVelocityTracker: ObservableObject {
    @Published var sessionVelocity: Double?      // %/hr, nil if insufficient data
    @Published var weeklyVelocity: Double?       // %/hr
    @Published var allTimeVelocity: Double?      // %/hr
    @Published var sessionTimeRemaining: TimeInterval?  // seconds until 100%
    @Published var sessionSampleCount: Int = 0
    @Published var detectedModel: String?               // "opus", "sonnet", "haiku", or nil
    @Published var perModelTimeRemaining: [String: TimeInterval] = [:]
    @Published var budgetAdvisorMessage: String?

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
        // Build model snapshots from breakdowns
        let snapshots = extractModelSnapshots(from: usage.breakdowns)

        // Detect active model by diffing with previous sample
        let detected = detectActiveModel(newSnapshots: snapshots, sessionDelta: usage.sessionUtilization - (samples.last?.sessionUtilization ?? 0))

        let sample = UsageSample(
            timestamp: Date(),
            sessionUtilization: usage.sessionUtilization,
            sessionResetsAt: usage.sessionResetsAt,
            modelSnapshots: snapshots,
            detectedModel: detected
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

    // MARK: - Model Detection

    /// Extract per-model 7-day snapshots from API breakdowns
    private func extractModelSnapshots(from breakdowns: [UsageBreakdown]) -> [ModelSnapshot] {
        var snapshots: [ModelSnapshot] = []
        for breakdown in breakdowns {
            let label = breakdown.label.lowercased()
            if label.contains("opus") {
                snapshots.append(ModelSnapshot(label: "opus", utilization: breakdown.utilization))
            } else if label.contains("sonnet") {
                snapshots.append(ModelSnapshot(label: "sonnet", utilization: breakdown.utilization))
            }
            // Note: Haiku has no dedicated 7-day breakdown in the API
        }
        return snapshots
    }

    /// Detect which model is active by comparing 7-day breakdown changes
    private func detectActiveModel(newSnapshots: [ModelSnapshot], sessionDelta: Double) -> String? {
        guard let lastSample = samples.last else { return nil }
        let oldSnapshots = lastSample.modelSnapshots

        // Build lookup of old values
        var oldValues: [String: Double] = [:]
        for s in oldSnapshots {
            oldValues[s.label] = s.utilization
        }

        // Find which model's 7-day increased the most
        var bestModel: String?
        var bestIncrease: Double = 0
        let threshold: Double = 0.05  // minimum increase to count

        for snapshot in newSnapshots {
            let oldVal = oldValues[snapshot.label] ?? 0
            let increase = snapshot.utilization - oldVal
            if increase > threshold && increase > bestIncrease {
                bestIncrease = increase
                bestModel = snapshot.label
            }
        }

        // If session usage went up but no per-model breakdown moved, infer Haiku
        if bestModel == nil && sessionDelta > 0.5 {
            bestModel = "haiku"
        }

        // If we detected something, return it. Otherwise keep previous detection.
        return bestModel ?? lastSample.detectedModel
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

        // Find session boundary: last time sessionResetsAt changed (jumped forward)
        let sessionSamples = samplesForCurrentSession()
        sessionSampleCount = sessionSamples.count

        sessionVelocity = computeVelocity(from: sessionSamples)
        weeklyVelocity = computeVelocity(from: samples.filter {
            $0.timestamp >= now.addingTimeInterval(-7 * 24 * 3600)
        })
        allTimeVelocity = computeVelocity(from: samples)

        // Update detected model from latest sample
        detectedModel = samples.last?.detectedModel

        // Estimate time remaining based on session velocity
        if let vel = sessionVelocity, vel > 0, currentUtilization < 100 {
            let hoursLeft = (100 - currentUtilization) / vel
            sessionTimeRemaining = hoursLeft * 3600
        } else {
            sessionTimeRemaining = nil
        }

        // Compute per-model time estimates
        computePerModelEstimates(currentUtilization: currentUtilization)

        // Generate budget advisor message
        generateBudgetAdvice(currentUtilization: currentUtilization)
    }

    /// Compute estimated time remaining for each model using pricing ratios
    private func computePerModelEstimates(currentUtilization: Double) {
        guard let vel = sessionVelocity, vel > 0, currentUtilization < 100 else {
            perModelTimeRemaining = [:]
            return
        }

        let currentModel = detectedModel ?? "sonnet"  // default assumption
        var estimates: [String: TimeInterval] = [:]

        for model in Constants.availableModels {
            let modelVel = Constants.ModelPricing.estimateVelocity(
                observed: vel, fromModel: currentModel, toModel: model
            )
            if modelVel > 0 {
                let hoursLeft = (100 - currentUtilization) / modelVel
                estimates[model] = hoursLeft * 3600
            }
        }

        perModelTimeRemaining = estimates
    }

    /// Generate budget advice when time is running low
    private func generateBudgetAdvice(currentUtilization: Double) {
        guard let currentModel = detectedModel,
              let currentRemaining = perModelTimeRemaining[currentModel],
              currentRemaining > 0 else {
            budgetAdvisorMessage = nil
            return
        }

        let thresholdSeconds = Constants.ModelPricing.advisorThresholdHours * 3600

        // Only advise if current model has < threshold time remaining
        guard currentRemaining < thresholdSeconds else {
            budgetAdvisorMessage = nil
            return
        }

        // Find the cheapest model that would give more time
        for cheaperModel in Constants.ModelPricing.modelsInCostOrder {
            if cheaperModel == currentModel { break }  // stop at current model
            if let cheaperRemaining = perModelTimeRemaining[cheaperModel], cheaperRemaining > currentRemaining {
                let estimate = ModelTimeEstimate(model: cheaperModel, timeRemaining: cheaperRemaining, isCurrent: false)
                budgetAdvisorMessage = "Switch to \(cheaperModel.capitalized) for \(estimate.displayString) remaining"
                return
            }
        }

        budgetAdvisorMessage = nil
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

    /// Active-only velocity: only counts time intervals where utilization actually changed.
    /// This gives "burn rate while actively using" not "average rate including idle time".
    private func computeVelocity(from windowSamples: [UsageSample]) -> Double? {
        guard windowSamples.count >= 2 else { return nil }

        var activeSeconds: TimeInterval = 0
        var activeDelta: Double = 0
        let changeThreshold: Double = 0.1  // minimum % change to count as active

        for i in 1..<windowSamples.count {
            let prev = windowSamples[i - 1]
            let curr = windowSamples[i]
            let delta = curr.sessionUtilization - prev.sessionUtilization

            if delta > changeThreshold {
                activeSeconds += curr.timestamp.timeIntervalSince(prev.timestamp)
                activeDelta += delta
            }
        }

        guard activeSeconds > 60, activeDelta > 0 else { return nil } // need >1 min of active data
        let activeHours = activeSeconds / 3600
        return activeDelta / activeHours
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

    var detectedModelDisplay: String {
        guard let model = detectedModel else { return "unknown" }
        return model.capitalized
    }

    /// Build model time estimates for SwiftUI display
    var modelTimeEstimates: [ModelTimeEstimate] {
        // Show in cost order: opus, sonnet, haiku (most expensive first)
        Constants.ModelPricing.modelsInCostOrder.reversed().map { model in
            ModelTimeEstimate(
                model: model,
                timeRemaining: perModelTimeRemaining[model],
                isCurrent: model == detectedModel
            )
        }
    }
}
