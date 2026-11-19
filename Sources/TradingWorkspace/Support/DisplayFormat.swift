import Foundation

enum DisplayFormat {
  static func priceDecimals(_ price: Double) -> Int {
    guard price.isFinite, price > 0 else { return 6 }
    return min(12, max(2, 4 - Int(floor(log10(price)))))
  }
  static func number(_ value: Decimal, decimals: Int = 6) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = decimals
    return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
  }
  static func currency(_ value: Decimal, decimals: Int = 2) -> String {
    "$" + number(value, decimals: decimals)
  }
  static func compactCurrency(_ value: Decimal) -> String {
    if value >= 1_000_000 { return currency(value / 1_000_000, decimals: 1) + "M" }
    if value >= 1_000 { return currency(value / 1_000, decimals: 1) + "K" }
    return currency(value)
  }
}
