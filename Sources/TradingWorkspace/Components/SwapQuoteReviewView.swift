import SwiftUI

struct SwapQuoteReviewView: View {
  let quote: SwapQuote
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      VStack(alignment: .leading, spacing: 20) {
        Text("Quote review").font(AppTypography.title2Semibold)
        Text(
          "Jupiter · \(quote.isFresh(at: context.date) ? "Read-only quote" : "Stale — refresh in the ticket")"
        )
        .foregroundStyle(quote.isFresh(at: context.date) ? Color.secondary : Color.orange)
        row("Input", "\(quote.payAmount) \(quote.paySymbol)")
        row("Estimated receive", "\(quote.receiveAmount) \(quote.receiveSymbol)")
        row("Minimum receive", "\(quote.minimumReceive) \(quote.receiveSymbol)")
        row("Jupiter fee", quote.feeText)
        row("Price impact", quote.impactText)
        row("Venues", quote.routes.isEmpty ? quote.router : quote.routes.joined(separator: " · "))
        Divider()
        Text(
          "Quote preview only. Wallet-dependent fees and costs are not estimated."
        )
        .font(AppTypography.callout).foregroundStyle(.secondary)
        HStack {
          Spacer()
          Button("Back to quote") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(
            .cancelAction)
        }
      }.padding(28).frame(width: 460)
    }.font(AppTypography.body)
  }
  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(value).monospacedDigit().multilineTextAlignment(.trailing)
    }
  }
}
