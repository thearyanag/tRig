import Foundation

/// Design fixtures: not live prices or connected-wallet balances.
struct SampleMarket: Sendable {
  let price: Decimal
  let changePercent: Decimal
  let volume: Decimal
  let liquidity: Decimal
  let usdcBalance: Decimal
  let assetBalance: Decimal
  let feeRate: Decimal

  /// Real asset reference price, with fixture balances/fees for local UI review only.
  static func preview(price: Double) -> SampleMarket {
    SampleMarket(
      price: Decimal(price), changePercent: 0, volume: 0, liquidity: 0,
      usdcBalance: 1000, assetBalance: 250, feeRate: Decimal(string: "0.001")!)
  }

  static let backpack = SampleMarket(
    price: Decimal(string: "0.42")!,
    changePercent: Decimal(string: "4.48")!,
    volume: 12_400_000, liquidity: 3_800_000,
    usdcBalance: 1_000, assetBalance: 250,
    feeRate: Decimal(string: "0.001")!
  )
}
