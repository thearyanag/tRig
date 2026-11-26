import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct WalletReceiveView: View {
  let accounts: [WalletAccount]
  @State private var family: WalletFamily
  @State private var copied = false
  private static let qrContext = CIContext()

  init(accounts: [WalletAccount], preferredFamily: WalletFamily) {
    self.accounts = accounts
    _family = State(initialValue: accounts.first { $0.family == preferredFamily }?.family
      ?? accounts.first?.family ?? preferredFamily)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      WalletFamilyTabs(families: accounts.map(\.family), selection: $family)
      if let account = accounts.first(where: { $0.family == family }) {
        addressCard(account)
        Text(account.family == .solana ? "Use this address on Solana." :
          "Select the EVM network in the sending wallet.")
          .font(AppTypography.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button {
          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          copied = pasteboard.setString(account.address, forType: .string)
        } label: {
          Label(copied ? "Copied" : "Copy address",
            systemImage: copied ? "checkmark" : "document.on.document")
            .font(AppTypography.calloutMedium)
            .frame(maxWidth: .infinity).frame(height: 36)
        }
        .buttonStyle(TerminalControlStyle.primary)
      }
    }
    .onChange(of: family) { _, _ in copied = false }
  }

  private func addressCard(_ account: WalletAccount) -> some View {
    VStack(spacing: 12) {
      if let image = qr(for: account) {
        Image(decorative: image, scale: 1)
          .interpolation(.none).resizable().scaledToFit().frame(width: 128, height: 128)
          .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 8))
          .accessibilityLabel("\(account.family.title) address QR code")
      }
      VStack(alignment: .leading, spacing: 5) {
        Text("\(account.family.title) address")
          .font(AppTypography.caption).foregroundStyle(.secondary)
        Text(verbatim: account.address)
          .font(.system(size: 11, design: .monospaced))
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(TerminalStyle.canvas, in: RoundedRectangle(cornerRadius: 6))
    }
    .frame(maxWidth: .infinity)
    .walletCard()
  }

  private func qr(for account: WalletAccount) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(account.receiveURI.utf8)
    guard let image = filter.outputImage else { return nil }
    return Self.qrContext.createCGImage(image, from: image.extent)
  }
}
