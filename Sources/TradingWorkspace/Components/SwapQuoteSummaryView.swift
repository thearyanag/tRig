import SwiftUI

struct SwapQuoteSummaryView: View {
  let quote: SwapQuote?

  var body: some View {
    VStack(spacing: 6) {
      row("Est. price", SwapTicketDisplay.price(quote))
      row("Minimum receive", quote.map { "\($0.minimumReceive) \($0.receiveSymbol)" } ?? "—")
      row("Price impact", quote?.impactText ?? "—")
      row("Jupiter fee", quote?.feeText ?? "—")
      if let quote {
        row("Route", quote.routes.isEmpty ? quote.router : quote.routes.joined(separator: " · "))
      }
    }
    .font(AppTypography.caption)
    .padding(8)
    .background(
      TerminalStyle.field.opacity(0.5),
      in: RoundedRectangle(cornerRadius: TerminalStyle.controlRadius)
    )
    .overlay(
      RoundedRectangle(cornerRadius: TerminalStyle.controlRadius).strokeBorder(TerminalStyle.border)
    )
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title).foregroundStyle(.secondary).fixedSize()
      Spacer(minLength: 0)
      Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        .lineLimit(2).textSelection(.enabled)
    }
  }
}
