import SwiftUI

struct TradeReviewView: View {
  let asset: Asset
  let preview: TradePreview
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Review \(preview.side.rawValue.lowercased()) · \(asset.symbol)")
          .font(.title2.weight(.semibold))
        Text("Sample trade preview").foregroundStyle(.secondary)
      }
      VStack(spacing: 14) {
        row("You pay", amount: preview.payAmount, symbol: preview.paySymbol)
        row("Estimated receive", amount: preview.receiveAmount, symbol: preview.receiveSymbol)
        row("Minimum receive", amount: preview.minimumReceive, symbol: preview.receiveSymbol)
        row("Sample fee", amount: preview.feeUSDC, symbol: "USDC")
        HStack {
          Text("Slippage").foregroundStyle(.secondary)
          Spacer()
          Text(preview.slippage.rawValue)
        }
      }
      Divider()
      Text(
        "This is a local UI estimate. Balances and fees are sample values. Network costs, routing and price impact are not included. No wallet is connected and no order will be placed."
      )
      .font(.callout).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Back to ticket") { dismiss() }
          .buttonStyle(.borderedProminent).keyboardShortcut(.cancelAction)
      }
    }
    .padding(28).frame(width: 440)
  }
  private func row(_ title: String, amount: Decimal, symbol: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text("\(DisplayFormat.number(amount)) \(symbol)").monospacedDigit()
    }
  }
}
