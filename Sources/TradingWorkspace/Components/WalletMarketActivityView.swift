import AppKit
import SwiftUI

struct WalletMarketActivityView: View {
  let wallet: WalletStore

  var body: some View {
    let entries = wallet.activityItems()
    if entries.isEmpty {
      Text(wallet.wallets.isEmpty ? "Add a tRig wallet to see its transactions." : "No wallet activity yet.")
        .font(AppTypography.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 0) {
        columns("Transaction", "Source", "Time", "Status")
          .font(AppTypography.caption).foregroundStyle(.secondary)
          .frame(height: 25)
        Divider()
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(entries) { entry in
              columns(
                entry.title, entry.source,
                entry.date.formatted(date: .abbreviated, time: .shortened),
                entry.status.label, statusColor: entry.status.tint
              )
              .font(AppTypography.callout)
              .frame(minHeight: 32)
              .contextMenu {
                Button("Copy transaction ID") {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(entry.transactionID, forType: .string)
                }
              }
              Divider()
            }
          }
        }
      }
      .padding(.horizontal, 16)
    }
  }

  private func columns(
    _ title: String, _ source: String, _ time: String, _ status: String, statusColor: Color = .secondary
  ) -> some View {
    HStack(spacing: 12) {
      Text(verbatim: title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
      Text(verbatim: source).lineLimit(1).frame(width: 108, alignment: .leading)
      Text(verbatim: time).lineLimit(1).frame(width: 148, alignment: .trailing)
      Text(verbatim: status).foregroundStyle(statusColor).frame(width: 92, alignment: .trailing)
    }
  }
}

extension WalletTradeStatus {
  var tint: Color {
    switch self {
    case .pending: .orange
    case .confirmed: TerminalStyle.buy
    case .failed: TerminalStyle.sell
    case .expired: .secondary
    }
  }
}
