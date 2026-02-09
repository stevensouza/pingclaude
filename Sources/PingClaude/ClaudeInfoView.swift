import SwiftUI

struct ClaudeInfoView: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var settings: SettingsStore

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
        }
        .padding(20)
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
