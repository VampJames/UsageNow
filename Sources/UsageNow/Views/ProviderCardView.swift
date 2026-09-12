import SwiftUI

struct ProviderCardView: View {
    let name: String
    let state: ProviderState
    let innerColor: Color
    let outerColor: Color
    let showResetTimes: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let snapshot = snapshot {
                DoubleRingView(
                    title: name,
                    innerProgress: PercentageFormatter.ringProgress(for: snapshot.innerMetric.percentUsed),
                    outerProgress: PercentageFormatter.ringProgress(for: snapshot.outerMetric.percentUsed),
                    innerColor: innerColor,
                    outerColor: outerColor,
                    innerAccessibilityLabel: "\(name) \(snapshot.innerMetric.title)，已使用 \(PercentageFormatter.displayText(for: snapshot.innerMetric.percentUsed))",
                    outerAccessibilityLabel: "\(name) \(snapshot.outerMetric.title)，已使用 \(PercentageFormatter.displayText(for: snapshot.outerMetric.percentUsed))"
                )
                metricRow(snapshot.innerMetric)
                metricRow(snapshot.outerMetric)
                if showResetTimes {
                    resetRow(snapshot.innerMetric)
                    resetRow(snapshot.outerMetric)
                }
            } else if case .loading = state {
                ProgressView()
                    .frame(height: 140)
            } else if case .unavailable(let message) = state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 140)
            }

            if case .stale(_, let message) = state {
                Text("数据可能已过期：\(message)")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var snapshot: UsageSnapshot? {
        switch state {
        case .available(let s), .stale(let s, _):
            return s
        default:
            return nil
        }
    }

    private func metricRow(_ metric: UsageMetric) -> some View {
        HStack {
            Text(metric.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(PercentageFormatter.displayText(for: metric.percentUsed))
                .font(.caption.monospacedDigit())
        }
    }

    private func resetRow(_ metric: UsageMetric) -> some View {
        HStack {
            Text(ResetTimeFormatter.format(resetAt: metric.resetAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}
