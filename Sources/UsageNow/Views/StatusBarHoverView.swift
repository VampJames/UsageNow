import SwiftUI

struct StatusBarHoverView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            providerRow(name: "Codex", state: store.codexState, showResetTimes: true)
            providerRow(name: "Cursor", state: store.cursorState, showResetTimes: false)
            if let updated = store.lastRefreshCompletedAt {
                Text("更新 \(timeString(updated))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func providerRow(name: String, state: ProviderState, showResetTimes: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption.bold())
            switch state {
            case .loading, .idle:
                Text("加载中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .available(let snapshot), .stale(let snapshot, _):
                HStack {
                    Text(snapshot.innerMetric.title)
                    Spacer()
                    Text(PercentageFormatter.displayText(for: snapshot.innerMetric.percentUsed))
                        .monospacedDigit()
                }
                .font(.caption)
                HStack {
                    Text(snapshot.outerMetric.title)
                    Spacer()
                    Text(PercentageFormatter.displayText(for: snapshot.outerMetric.percentUsed))
                        .monospacedDigit()
                }
                .font(.caption)
                if showResetTimes {
                    Text("5 小时重置：\(ResetTimeFormatter.format(resetAt: snapshot.innerMetric.resetAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("周额度重置：\(ResetTimeFormatter.format(resetAt: snapshot.outerMetric.resetAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .unavailable(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = .current
        return f.string(from: date)
    }
}
