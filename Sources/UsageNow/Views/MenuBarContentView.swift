import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("UsageNow")
                    .font(.title3.bold())
                Spacer()
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
                .accessibilityLabel("刷新用量")
            }

            HStack(alignment: .top, spacing: 12) {
                ProviderCardView(
                    name: "Codex",
                    state: store.codexState,
                    innerColor: Color(red: 0.2, green: 0.75, blue: 0.65),
                    outerColor: Color(red: 0.25, green: 0.45, blue: 0.95),
                    showResetTimes: true
                )
                ProviderCardView(
                    name: "Cursor",
                    state: store.cursorState,
                    innerColor: Color.orange,
                    outerColor: Color.purple,
                    showResetTimes: false
                )
            }

            StatusFooterView(lastUpdated: store.lastRefreshCompletedAt) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(16)
        .frame(width: 460, height: 340)
        .onAppear { store.setPopoverOpen(true) }
        .onDisappear { store.setPopoverOpen(false) }
    }
}
