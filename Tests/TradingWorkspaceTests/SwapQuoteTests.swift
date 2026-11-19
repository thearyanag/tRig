import Foundation
import Testing

@testable import TradingWorkspace

private func input(_ amount: String = "100") -> SwapQuoteInput {
  SwapQuoteInput(asset: .backpack, draft: TradeDraft(amountText: amount))
}
private func response(
  _ input: SwapQuoteInput, fetchedAt: Double = Date().timeIntervalSince1970,
  receiveAmount: String = "2"
)
  throws -> SwapQuote
{
  let body: [String: Any] = [
    "assetMint": input.assetMint, "side": input.side, "requestedAmount": input.amount,
    "inputMint": input.side == "buy" ? SwapQuoteInput.usdc : input.assetMint,
    "outputMint": input.side == "buy" ? input.assetMint : SwapQuoteInput.usdc,
    "inAmount": "100000000",
    "outAmount": "2000000000",
    "inputDecimals": 6, "outputDecimals": 9, "payAmount": input.amount, "paySymbol": "USDC",
    "receiveAmount": receiveAmount, "receiveSymbol": input.side == "buy" ? "BP" : "USDC",
    "minimumReceive": "1.99",
    "slippageBps": input.slippageBps,
    "feeBps": 10, "feeSymbol": "BP", "priceImpactPercent": -0.1, "routes": ["Venue"],
    "router": "metis",
    "fetchedAt": fetchedAt, "expiresAt": fetchedAt + 20,
  ]
  return try JSONDecoder().decode(
    SwapQuote.self, from: JSONSerialization.data(withJSONObject: body))
}

@Test func quoteInputsAndFreshnessAreBounded() throws {
  for value in ["", "0", "-1", "1e3", "1,000", ".", "1.2.3"] { #expect(!input(value).isValid) }
  #expect(input("0.000000001").isValid)
  let quote = try response(input())
  #expect(quote.matches(input()))
  #expect(!quote.matches(input("101")))
  #expect(quote.isFresh(at: Date(timeIntervalSince1970: quote.fetchedAt + 19)))
  #expect(!quote.isFresh(at: Date(timeIntervalSince1970: quote.fetchedAt + 21)))
}

@MainActor private final class ControlledQuotes {
  var pending: [String: CheckedContinuation<SwapQuote, Error>] = [:]
  func fetch(_ value: SwapQuoteInput) async throws -> SwapQuote {
    try await withCheckedThrowingContinuation { pending[value.amount] = $0 }
  }
  func complete(_ value: SwapQuoteInput) throws {
    pending.removeValue(forKey: value.amount)?.resume(returning: try response(value))
  }
}
@MainActor private func until(_ condition: () -> Bool) async {
  for _ in 0..<1000 {
    if condition() { return }
    await Task.yield()
  }
  Issue.record("Quote state did not settle")
}

@Test @MainActor func lateQuotesCannotReplaceAnEditedAmount() async throws {
  let client = ControlledQuotes()
  let store = SwapQuoteStore(fetch: { try await client.fetch($0) })
  let first = input("100")
  let second = input("101")
  store.load(first)
  await until { client.pending[first.amount] != nil }
  store.load(second)
  await until { client.pending[second.amount] != nil }
  try client.complete(second)
  await until { store.quote != nil }
  #expect(store.quote?.requestedAmount == "101")
  #expect(store.visibleQuote(for: first) == nil)
  try client.complete(first)
  await Task.yield()
  #expect(store.quote?.requestedAmount == "101")
}

@Test @MainActor func clearingTheTicketDiscardsAnInFlightResponse() async throws {
  let client = ControlledQuotes()
  let store = SwapQuoteStore(fetch: { try await client.fetch($0) })
  store.load(input())
  await until { client.pending["100"] != nil }
  store.clear()
  try client.complete(input())
  await Task.yield()
  #expect(store.quote == nil)
  #expect(!store.isLoading)
}

@Test func selectingTheOtherQuoteSideClearsAmountsInDifferentUnits() {
  var draft = TradeDraft(amountText: "100", slippage: .high)
  draft.selectQuoteSide(.buy)
  #expect(draft.amountText == "100")
  draft.selectQuoteSide(.sell)
  #expect(draft.side == .sell)
  #expect(draft.amountText.isEmpty)
  #expect(draft.slippage == .high)
}

@Test func reversingAFreshQuoteUsesItsReceiveAmountInTheNewToken() throws {
  for side in TradeSide.allCases {
    var draft = TradeDraft(side: side, amountText: "100", slippage: .high)
    let quote = try response(SwapQuoteInput(asset: .backpack, draft: draft), receiveAmount: "4.25")
    draft.reverseQuote(asset: .backpack, quote: quote, at: Date())
    #expect(draft.side == (side == .buy ? .sell : .buy))
    #expect(draft.amountText == "4.25")
    #expect(draft.slippage == .high)
  }
}

@Test func reversingWithoutAMatchingFreshQuoteRequiresANewAmount() throws {
  let quotes: [SwapQuote?] = [
    nil,
    try response(input(), fetchedAt: Date().timeIntervalSince1970 - 30),
    try response(input("101")),
  ]
  for quote in quotes {
    var draft = TradeDraft(amountText: "100")
    draft.reverseQuote(asset: .backpack, quote: quote, at: Date())
    #expect(draft.side == .sell)
    #expect(draft.amountText.isEmpty)
  }
}

@Test func quoteFiatDisplayRejectsPartialNumbersAndRequiresAssetPricing() throws {
  for text in ["1abc", "1,000", "1e3", "-1", ".", ""] {
    #expect(SwapTicketDisplay.fiat(text, isUSDC: true, referencePrice: nil) == nil)
  }
  #expect(SwapTicketDisplay.fiat("100", isUSDC: true, referencePrice: nil) == "≈ $100")
  #expect(SwapTicketDisplay.fiat("2", isUSDC: false, referencePrice: nil) == nil)
  #expect(SwapTicketDisplay.fiat("2", isUSDC: false, referencePrice: 1.25) == "≈ $2.5")
  #expect(SwapTicketDisplay.price(try response(input())) == "$50")
}
