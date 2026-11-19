import Foundation

enum SwapTicketDisplay {
  static func fiat(_ text: String?, isUSDC: Bool, referencePrice: Double?) -> String? {
    guard let text,
      text.range(of: "^(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$", options: .regularExpression) != nil,
      let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
      !amount.isNaN, amount >= 0
    else { return nil }
    if isUSDC { return "≈ " + DisplayFormat.currency(amount) }
    guard let referencePrice, referencePrice.isFinite, referencePrice > 0 else { return nil }
    return "≈ " + DisplayFormat.currency(amount * Decimal(referencePrice))
  }

  static func price(_ quote: SwapQuote?) -> String {
    guard let quote, let paid = Decimal(string: quote.payAmount),
      let received = Decimal(string: quote.receiveAmount), paid > 0, received > 0
    else { return "—" }
    let price = quote.side == "buy" ? paid / received : received / paid
    return DisplayFormat.currency(
      price, decimals: DisplayFormat.priceDecimals(NSDecimalNumber(decimal: price).doubleValue))
  }
}
