import SwiftUI

struct StatusFooterView: View {
    let lastUpdated: Date?
    let onQuit: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = .current
        return f
    }()

    var body: some View {
        HStack {
            if let lastUpdated {
                Text("最后更新：\(Self.timeFormatter.string(from: lastUpdated))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("最后更新：—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("退出", action: onQuit)
                .accessibilityLabel("退出 UsageNow")
        }
    }
}
