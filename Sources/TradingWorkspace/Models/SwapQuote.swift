import Foundation

struct SwapQuoteInput: Hashable, Sendable {
  static let usdc = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
  let assetMint: String
  let side: String
  let amount: String
  let slippageBps: Int

  init(asset: Asset, draft: TradeDraft) {
    assetMint = asset.id
    side = draft.side.rawValue.lowercased()
    amount = draft.quoteAmount
    slippageBps = draft.slippage.basisPoints
  }
  var isValid: Bool {
    assetMint != Self.usdc && QuoteAmount.isPositive(amount)
  }
}

struct SwapQuote: Decodable, Identifiable, Equatable, Sendable {
  let assetMint: String
  let side: String
  let inputMint: String
  let requestedAmount: String
  let outputMint: String
  let inAmount: String
  let outAmount: String
  let inputDecimals: Int
  let outputDecimals: Int
  let payAmount: String
  let paySymbol: String
  let receiveAmount: String
  let receiveSymbol: String
  let minimumReceive: String
  let slippageBps: Int
  let feeBps: Int
  let feeSymbol: String
  let priceImpactPercent: Double?
  let routes: [String]
  let router: String
  let fetchedAt: Double
  let expiresAt: Double
  var id: String { "\(inputMint):\(outputMint):\(inAmount):\(slippageBps):\(fetchedAt)" }
  func isFresh(at date: Date) -> Bool { date.timeIntervalSince1970 < expiresAt }
  func matches(_ input: SwapQuoteInput) -> Bool {
    assetMint == input.assetMint && side == input.side && slippageBps == input.slippageBps
      && requestedAmount == input.amount
      && inputMint == (side == "buy" ? SwapQuoteInput.usdc : input.assetMint)
      && outputMint == (side == "buy" ? input.assetMint : SwapQuoteInput.usdc)
      && Date().timeIntervalSince1970 >= fetchedAt - 5
  }
  var feeText: String {
    "\(DisplayFormat.number(Decimal(feeBps) / 100, decimals: 2))%\(feeBps == 0 || feeSymbol.isEmpty ? "" : " · \(feeSymbol)")"
  }
  var impactText: String {
    priceImpactPercent.map { "\(DisplayFormat.number(Decimal($0), decimals: 4))%" } ?? "Unavailable"
  }
}
