import AppKit
import SwiftUI

struct WalletActivityView: View {
  let store: WalletStore
  let wallet: TradingWallet?

  var body: some View {
    let entries = store.activityItems(for: wallet)
    let refreshing = store.activity.refreshing || store.trades.refreshing
    if entries.isEmpty {
      Label("No wallet activity yet.", systemImage: "clock")
        .font(AppTypography.callout).foregroundStyle(.secondary)
        .walletCard()
    } else {
      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(entries) { entry in
            let tint = entry.status.tint
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(AppTypography.calloutMedium)
                Text("\(entry.source) · \(entry.date.formatted(date: .omitted, time: .shortened))")
                  .font(AppTypography.caption).foregroundStyle(.secondary)
                Text(verbatim: entry.transactionID).font(.system(size: 10, design: .monospaced))
                  .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
              }
              Spacer(minLength: 6)
              Text(entry.status.label).foregroundStyle(tint)
                .font(AppTypography.caption)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(tint.opacity(0.12), in: Capsule())
            }
            .walletCard(padding: 10)
            .contextMenu {
              Button("Copy transaction ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.transactionID, forType: .string)
              }
              if entry.chain == "solana",
                let url = URL(string: "https://solscan.io/tx/\(entry.transactionID)") {
                Link("View on Solscan", destination: url)
              }
            }
          }
        }
      }.frame(maxHeight: 220)
      Button {
        Task { await store.refreshActivity() }
      } label: {
        Label(refreshing ? "Checking…" : "Check status", systemImage: "arrow.clockwise")
          .font(AppTypography.calloutMedium).frame(maxWidth: .infinity).frame(height: 34)
      }.buttonStyle(TerminalControlStyle()).disabled(refreshing)
        .task { await store.refreshActivity() }
    }
  }
}
