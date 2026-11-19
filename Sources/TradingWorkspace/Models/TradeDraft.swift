import Foundation

enum TradeSide: String, CaseIterable, Identifiable, Sendable {
  case buy = "Buy"
  case sell = "Sell"
  var id: Self { self }
}

enum SlippagePreset: String, CaseIterable, Identifiable, Sendable {
  case low = "0.1%"
  case standard = "0.5%"
  case high = "1%"
  var id: Self { self }
  var fraction: Decimal {
    switch self {
    case .low: Decimal(string: "0.001")!
    case .standard: Decimal(string: "0.005")!
    case .high: Decimal(string: "0.01")!
    }
  }
}

enum TradeInputError: String, Error, Equatable {
  case empty = "Enter an amount to review."
  case invalid = "Enter a positive number with up to 6 decimal places."
  case insufficient = "Amount exceeds the sample balance."
  case unavailable = "A sample price is unavailable."
  case tooSmall = "Amount is too small to estimate."
}

struct TradePreview: Identifiable, Sendable {
  let id = UUID()
  let side: TradeSide
  let payAmount: Decimal
  let paySymbol: String
  let receiveAmount: Decimal
  let receiveSymbol: String
  let feeUSDC: Decimal
  let minimumReceive: Decimal
  let slippage: SlippagePreset
}

struct TradeDraft {
  var side: TradeSide = .buy
  var amountText = "100"
  var slippage: SlippagePreset = .standard

  func preview(asset: Asset, market: SampleMarket) -> Result<TradePreview, TradeInputError> {
    let text = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return .failure(.empty) }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    let digits = text.filter { $0 != "." }
    guard parts.count <= 2, !digits.isEmpty,
      digits.allSatisfy({ $0.isASCII && $0.isNumber }),
      parts.count == 1 || parts[1].count <= 6,
      let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
      !amount.isNaN, amount > 0
    else { return .failure(.invalid) }
    guard market.price > 0, market.feeRate >= 0, market.feeRate < 1 else {
      return .failure(.unavailable)
    }
    guard amount <= (side == .buy ? market.usdcBalance : market.assetBalance) else {
      return .failure(.insufficient)
    }
    // Local estimate only: fee deducted from gross value. No routing or network costs.
    let grossUSDC = side == .buy ? amount : amount * market.price
    let fee = grossUSDC * market.feeRate
    let receive = roundedDown(side == .buy ? (grossUSDC - fee) / market.price : grossUSDC - fee)
    guard receive > 0 else { return .failure(.tooSmall) }
    return .success(
      TradePreview(
        side: side, payAmount: amount, paySymbol: side == .buy ? "USDC" : asset.symbol,
        receiveAmount: receive, receiveSymbol: side == .buy ? asset.symbol : "USDC",
        feeUSDC: fee, minimumReceive: roundedDown(receive * (1 - slippage.fraction)),
        slippage: slippage
      ))
  }

  private func roundedDown(_ value: Decimal) -> Decimal {
    var input = value
    var result = Decimal()
    NSDecimalRound(&result, &input, 6, .down)
    return result
  }
}
