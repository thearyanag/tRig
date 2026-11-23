import Foundation

/// Design fixtures: not live prices or connected-wallet balances.
struct SampleMarket: Sendable {
  let price: Decimal
  let changePercent: Decimal
  let volume: Decimal
  let usdcBalance: Decimal
  let assetBalance: Decimal
  let feeRate: Decimal

  static let backpack = SampleMarket(
    price: Decimal(string: "0.42")!,
    changePercent: Decimal(string: "4.48")!,
    volume: 12_400_000,
    usdcBalance: 1_000, assetBalance: 250,
    feeRate: Decimal(string: "0.001")!
  )
}
