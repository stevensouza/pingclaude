import SwiftUI

struct ClaudeInfoView: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var settings: SettingsStore
    @ObservedObject var velocityTracker: UsageVelocityTracker

    var body: some View {
        ScrollView {
            if !settings.hasUsageAPIConfig {
                noDataView
            } else if let usage = usageService.latestUsage {
                usageDashboard(usage)
            } else {
                loadingView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var noDataView: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 60)
            Text("No usage data available")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Configure your Claude Web API credentials in Settings to see live usage data here.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 60)
            ProgressIndicator()
            Text("Fetching usage data...")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func usageDashboard(_ usage: UsageData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Plan Tier
            if let plan = usageService.planTier {
                HStack(spacing: 8) {
                    Text("Claude \(plan.description)")
                        .font(.system(size: 18, weight: .bold))
                    Spacer()
                    Text(planBadgeText(plan))
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(planBadgeColor(plan).opacity(0.15))
                        .foregroundColor(planBadgeColor(plan))
                        .cornerRadius(6)
                }
                .padding(.bottom, 4)
            }

            // Session Usage
            GroupBox(label: Text("Session Usage").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    UsageBar(
                        label: "Session",
                        percentage: usage.sessionUtilization,
                        detail: resetDetail(usage)
                    )
                }
                .padding(.top, 4)
            }

            // Usage Pace
            GroupBox(label: Text("Usage Pace").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        // Detected model indicator
                        HStack {
                            Text("Active model:")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 90, alignment: .leading)
                            Text(velocityTracker.detectedModelDisplay)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.accentColor)
                            Spacer()
                        }

                        HStack {
                            Text("This session:")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 90, alignment: .leading)
                            Text(velocityTracker.sessionVelocityString)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Text(velocityTracker.timeRemainingString)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(timeRemainingColor)
                        }
                    }

                    Group {
                        HStack {
                            Text("Past week:")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 90, alignment: .leading)
                            Text(velocityTracker.weeklyVelocityString)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                        }

                        HStack {
                            Text("All time:")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 90, alignment: .leading)
                            Text(velocityTracker.allTimeVelocityString)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                        }
                    }

                    // Per-model time remaining table
                    if !velocityTracker.modelTimeEstimates.isEmpty &&
                       velocityTracker.modelTimeEstimates.contains(where: { $0.timeRemaining != nil }) {
                        Divider()
                        Text("Estimated time by model:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)

                        ForEach(velocityTracker.modelTimeEstimates) { estimate in
                            HStack {
                                Text(estimate.model.capitalized)
                                    .font(.system(size: 12, weight: estimate.isCurrent ? .semibold : .regular))
                                    .frame(width: 60, alignment: .leading)
                                Text(estimate.displayString)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(modelTimeColor(estimate))
                                if estimate.isCurrent {
                                    Text("(current)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }

                    // Budget advisor tip
                    if let advice = velocityTracker.budgetAdvisorMessage {
                        HStack(spacing: 4) {
                            Text("\u{1F4A1}")
                                .font(.system(size: 11))
                            Text(advice)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.orange)
                        }
                        .padding(.vertical, 2)
                    }

                    Text("Based on \(velocityTracker.sessionSampleCount) samples since last reset")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }

            // Weekly Usage
            GroupBox(label: Text("Weekly Usage").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    if let weekly = usage.weeklyUtilization {
                        UsageBar(
                            label: "Overall (7-day)",
                            percentage: weekly,
                            detail: weeklyResetDetail(usage)
                        )
                    } else {
                        Text("No weekly data")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }

                    ForEach(Array(usage.breakdowns.enumerated()), id: \.offset) { _, breakdown in
                        UsageBar(
                            label: breakdown.label,
                            percentage: breakdown.utilization,
                            detail: breakdownResetDetail(breakdown)
                        )
                    }
                }
                .padding(.top, 4)
            }

            // Monthly Spend
            GroupBox(label: Text("Monthly Spend").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    if let limit = usage.monthlyLimitCents, let used = usage.monthlyUsedCents, limit > 0 {
                        let pct = min(Double(used) / Double(limit) * 100, 100)
                        UsageBar(
                            label: "Extra usage credits",
                            percentage: pct,
                            detail: String(format: "$%.2f / $%.2f", Double(used) / 100.0, Double(limit) / 100.0)
                        )

                        if usage.outOfCredits == true {
                            Text("Out of credits!")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.red)
                        }
                    } else {
                        Text("No spend data available")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 4)
            }

            // Last updated
            if let error = usageService.lastError {
                HStack(spacing: 4) {
                    Text("\u{26A0}")
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }

            HStack {
                Text("Last updated: \(formattedFetchTime(usage.fetchedAt)) \u{00B7} Auto-refreshes every \(formattedPollInterval)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Refresh") {
                    usageService.fetchUsage()
                }
            }
            Text("Usage polling is free \u{2014} no tokens consumed, no sessions started.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            // Log & Troubleshooting
            GroupBox(label: Text("Log & Troubleshooting").font(.headline)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("All API calls (usage, spend, plan) are logged with status codes and key values.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 3) {
                        logLocationRow("Event log:", path: "~/Library/Logs/PingClaude/pingclaude.log")
                        logLocationRow("Ping history:", path: "~/Library/Logs/PingClaude/ping_history.json")
                        logLocationRow("Usage samples:", path: "~/Library/Logs/PingClaude/usage_samples.json")
                    }

                    Divider()

                    Text("Quick troubleshooting:")
                        .font(.system(size: 11, weight: .medium))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\u{2022} Plan shows \"--\": Check Web API credentials in Settings")
                        Text("\u{2022} Auth errors: Re-enter session key from browser")
                        Text("\u{2022} Parse errors: API response format may have changed")
                        Text("\u{2022} System diagnostics: Open Console.app, filter by \"PingClaude\"")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text("PingClaude Version: v\(Constants.buildVersion)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("Date Compiled: \(formattedBuildDate())")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
    }

    private var timeRemainingColor: Color {
        guard let hours = velocityTracker.timeRemainingHours else { return .secondary }
        if hours < 1 { return .red }
        if hours < 2 { return .orange }
        return .green
    }

    private func modelTimeColor(_ estimate: ModelTimeEstimate) -> Color {
        guard let remaining = estimate.timeRemaining else { return .secondary }
        let hours = remaining / 3600
        if hours < 1 { return .red }
        if hours < 2 { return .orange }
        return .green
    }

    private func resetDetail(_ usage: UsageData) -> String {
        var parts: [String] = []
        if let remaining = usage.sessionResetsInString {
            parts.append("resets in \(remaining)")
        }
        if let resetTime = usage.sessionResetTimeString {
            parts.append("at \(resetTime)")
        }
        return parts.joined(separator: " ")
    }

    private func weeklyResetDetail(_ usage: UsageData) -> String {
        guard let resetsAt = usage.weeklyResetsAt else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return "resets \(formatter.string(from: resetsAt))"
    }

    private func breakdownResetDetail(_ breakdown: UsageBreakdown) -> String {
        guard let resetsAt = breakdown.resetsAt else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return "resets \(formatter.string(from: resetsAt))"
    }

    private var formattedPollInterval: String {
        let secs = settings.usagePollingSeconds
        if secs < 60 { return "\(secs) sec" }
        return "\(secs / 60) min"
    }

    private func formattedFetchTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        return formatter.string(from: date)
    }

    private func formattedBuildDate() -> String {
        let version = Constants.buildVersion
        // Version format: YYYYMMDD.HHMMSS (e.g., "20260211.064938")
        let parts = version.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return version }

        let dateStr = String(parts[0])  // "20260211"
        let timeStr = String(parts[1])  // "064938"

        guard dateStr.count == 8, timeStr.count == 6 else { return version }

        let year = String(dateStr.prefix(4))
        let month = String(dateStr.dropFirst(4).prefix(2))
        let day = String(dateStr.dropFirst(6))
        let hour = String(timeStr.prefix(2))
        let minute = String(timeStr.dropFirst(2).prefix(2))
        let second = String(timeStr.dropFirst(4))

        // Format as "Feb 11, 2026 6:49:38 AM"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime]

        if let date = formatter.date(from: "\(year)-\(month)-\(day)T\(hour):\(minute):\(second)Z") {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "MMM dd, yyyy h:mm:ss a"
            return displayFormatter.string(from: date)
        }

        return version
    }

    @ViewBuilder
    private func logLocationRow(_ label: String, path: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 100, alignment: .leading)
            Text(path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }

    private func planBadgeText(_ plan: PlanTier) -> String {
        switch plan {
        case .free: return "Free Tier"
        case .pro: return "Pro"
        case .max5x: return "Max 5x"
        case .max20x: return "Max 20x"
        case .team: return "Team"
        case .enterprise: return "Enterprise"
        case .unknown: return "Unknown"
        }
    }

    private func planBadgeColor(_ plan: PlanTier) -> Color {
        switch plan {
        case .free: return .secondary
        case .pro: return .blue
        case .max5x, .max20x: return .purple
        case .team: return .green
        case .enterprise: return .orange
        case .unknown: return .secondary
        }
    }
}

struct UsageBar: View {
    let label: String
    let percentage: Double
    var detail: String = ""

    private var barColor: Color {
        if percentage >= 80 { return .red }
        if percentage >= 50 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(percentage))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(barColor)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                        .frame(width: max(0, geometry.size.width * CGFloat(min(percentage, 100)) / 100), height: 8)
                }
            }
            .frame(height: 8)

            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct ProgressIndicator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.startAnimation(nil)
        return indicator
    }

    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {}
}
