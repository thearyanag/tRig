import Foundation

enum PortfolioFormat {
  static func decimal(_ value: String?) -> Decimal? {
    guard let value, let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
      !number.isNaN
    else { return nil }
    return number
  }
  static func currency(_ value: String?, signed: Bool = false, price: Bool = false) -> String {
    guard let amount = decimal(value) else { return "—" }
    let absolute = abs(amount)
    let digits =
      price ? DisplayFormat.priceDecimals(NSDecimalNumber(decimal: absolute).doubleValue) : 2
    if !price && absolute > 0 && absolute < Decimal(string: "0.01")! {
      return (amount < 0 ? "−" : signed ? "+" : "") + "<$0.01"
    }
    return (amount < 0 ? "−" : signed && amount > 0 ? "+" : "")
      + "$" + formatted(absolute, minimum: 2, maximum: digits)
  }
  static func quantity(_ value: String?) -> String {
    guard let amount = decimal(value) else { return value ?? "—" }
    let n = NSDecimalNumber(decimal: abs(amount)).doubleValue
    let decimals = n > 0 && n < 1 ? min(18, DisplayFormat.priceDecimals(n) + 2) : 6
    if amount != 0 && abs(amount) < Decimal(string: "0.000000000000000001")! {
      return "<0.000000000000000001"
    }
    return formatted(amount, maximum: decimals)
  }
  static func percent(_ value: String?) -> String? {
    guard let number = decimal(value) else { return nil }
    return (number > 0 ? "+" : "") + formatted(number, minimum: 2, maximum: 2) + "%"
  }
  private static func formatted(_ value: Decimal, minimum: Int = 0, maximum: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    formatter.minimumFractionDigits = minimum
    formatter.maximumFractionDigits = maximum
    return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
  }
  static func chainName(_ chain: String) -> String {
    switch chain {
    case "solana": "Solana"
    case "eip155:1": "Ethereum"
    case "eip155:8453": "Base"
    case "eip155:56": "BNB Chain"
    case "eip155:143": "Monad"
    case "eip155:4663": "Robinhood Chain"
    case "eip155:5042": "Arc"
    case "eip155:99901": "Elysium"
    case "hyperliquid:mainnet": "Hyperliquid"
    default: chain
    }
  }
}
