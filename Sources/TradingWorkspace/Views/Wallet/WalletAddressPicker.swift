import AppKit
import SwiftUI

struct WalletAddressPicker: View {
  let accounts: [WalletAccount]
  @State private var copiedAccount: WalletAccount.ID?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Copy address").font(AppTypography.bodySemibold).accessibilityAddTraits(.isHeader)
      VStack(spacing: 0) {
        ForEach(accounts) { account in
          if account.id != accounts.first?.id { Divider() }
          addressRow(account)
        }
      }
    }
    .padding(12)
    .frame(width: 270)
    .background(TerminalStyle.panel)
  }

  private func addressRow(_ account: WalletAccount) -> some View {
    let label = account.family == .solana ? "Solana" : "EVM address"
    let copied = copiedAccount == account.id
    return Button {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      if pasteboard.setString(account.address, forType: .string) { copiedAccount = account.id }
    } label: {
      HStack(spacing: 8) {
        if account.family == .solana {
          AssetIconView(asset: .solana, size: 16).accessibilityHidden(true)
        } else {
          Image(systemName: "diamond").frame(width: 16).accessibilityHidden(true)
        }
        Text(label).font(AppTypography.calloutMedium)
        Spacer(minLength: 6)
        Text(copied ? "Copied" : account.shortAddress)
          .font(AppTypography.caption).monospaced().foregroundStyle(copied ? TerminalStyle.buy : .secondary)
          .lineLimit(1)
        Image(systemName: copied ? "checkmark" : "document.on.document")
          .foregroundStyle(copied ? TerminalStyle.buy : .secondary)
      }
      .padding(.horizontal, 4).frame(height: 34)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(copied ? "\(label) copied" : "Copy \(label)")
  }
}
