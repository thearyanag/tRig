import Foundation
import Testing

@testable import TradingWorkspace

private func request(_ provider: ExecutionProvider = .jupiter) -> ExecutionQuoteRequest {
  ExecutionQuoteRequest(
    provider: provider, input: .init(chain: "solana", address: SwapQuoteInput.usdc),
    output: .init(chain: "solana", address: "So11111111111111111111111111111111111111112"),
    amount: "100", orderType: .market,
    slippageBps: 50, context: .init(sender: nil, recipient: nil))
}
private func quote(_ request: ExecutionQuoteRequest, receiveAmount: String = "1.2") throws
  -> ExecutionQuote
{
  let now = Date().timeIntervalSince1970
  return try JSONDecoder().decode(
    ExecutionQuote.self,
    from: JSONSerialization.data(withJSONObject: [
      "provider": (request.provider ?? .jupiter).rawValue, "providerName": "Fixture",
      "providerQuoteId": "fixture",
      "input": [
        "chain": request.input.chain, "address": request.input.address, "symbol": "USDC",
        "decimals": 6,
      ],
      "output": [
        "chain": request.output.chain, "address": request.output.address, "symbol": "SOL",
        "decimals": 9,
      ],
      "orderType": request.orderType.rawValue, "requestedAmount": request.amount,
      "payAmount": request.amount, "receiveAmount": receiveAmount,
      "minimumReceive": "1.1", "slippageBps": 50, "fees": [], "routes": [], "fetchedAt": now,
      "expiresAt": now + 20,
      "expiryKind": "app-freshness", "indicative": true, "warnings": [],
      "request": try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)),
    ]))
}
@Test func quoteRequestsKeepFundingOptionalAndRejectInvalidAmounts() {
  var r = request()
  #expect(r.isValid)
  #expect(r.context.sender == nil)
  for amount in ["0", "-1", "1e3", "1,000", "NaN", "1.2.3", " 5 "] {
    r.amount = amount
    #expect(!r.isValid)
  }
}
@Test func conditionalQuotesRequireAValidPriceAndSameChainPair() {
  var r = request(.flash)
  r.orderType = .limit
  #expect(!r.isValid)
  r.limitPriceUsd = "100"
  #expect(r.isValid)
  r.output.chain = "eip155:8453"
  #expect(!r.isValid)
  r.output.chain = "solana"
  r.orderType = .stopLoss
  r.limitPriceUsd = nil
  r.triggerPriceUsd = "90"
  #expect(r.isValid)
}
@Test func quoteIdentityIncludesProviderChainsAndAddressContext() throws {
  let r = request()
  let q = try quote(request())
  #expect(q.matches(r))
  var changed = r
  changed.provider = .relay
  #expect(!q.matches(changed))
  changed = r
  changed.output.chain = "eip155:8453"
  #expect(!q.matches(changed))
  changed = r
  changed.context.sender = "public-context"
  #expect(!q.matches(changed))
}
@Test(arguments: [false, true])
@MainActor func lateQuotesCannotReplaceAProviderChangeOrRetry(sameRequest: Bool) async throws {
  var calls: [CheckedContinuation<ExecutionQuote, any Error>] = []
  let store = ExecutionQuoteStore(fetch: { _ in
    try await withCheckedThrowingContinuation { calls.append($0) }
  })
  let first = request(.jupiter)
  let second = sameRequest ? first : request(.relay)
  store.load(first)
  while calls.count < 1 { await Task.yield() }
  store.load(second)
  while calls.count < 2 { await Task.yield() }
  calls[1].resume(returning: try quote(second))
  while store.isLoading { await Task.yield() }
  calls[0].resume(returning: try quote(first, receiveAmount: "1.1"))
  await Task.yield()
  #expect(store.quote?.provider == second.provider)
  #expect(store.visible(for: second)?.receiveAmount == "1.2")
  if !sameRequest { #expect(store.visible(for: first) == nil) }
}

@Test @MainActor func executionStoreRejectsAResponseFromAnotherProvider() async {
  let store = ExecutionQuoteStore(fetch: { _ in try quote(request(.relay)) })
  store.load(request(.jupiter))
  for _ in 0..<1000 {
    if !store.isLoading { break }
    await Task.yield()
  }
  #expect(!store.isLoading)
  #expect(store.quote == nil)
  #expect(store.error == "Quote identity could not be confirmed. Refresh to try again.")
}
