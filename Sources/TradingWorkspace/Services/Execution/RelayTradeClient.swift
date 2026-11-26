import Foundation

struct RelayTradePlan: Codable, Sendable, Identifiable {
  enum Action: String, Codable, Sendable { case approve, deposit }

  let requestId: String
  let request: ExecutionQuoteRequest
  let action: Action
  let chainId: UInt64
  let from: String
  let token: String
  let depository: String
  let orderId: String
  let nonce: String
  let gasPrice: String
  let gasLimit: String
  let feeAtomic: String
  let amountAtomic: String
  let tokenDecimals: UInt8
  let feeDecimals: UInt8
  let expiresAt: UInt64
  let minimumReceive: String
  let receiveAmount: String
  let payBalance: String
  let inputNetwork: String
  let outputNetwork: String
  let fee: String
  let feeSymbol: String

  var id: String { requestId }
  var expiry: Date { Date(timeIntervalSince1970: Double(expiresAt)) }
}

@MainActor
struct RelayTradeClient {
  func prepare(_ request: ExecutionQuoteRequest, quote: ExecutionQuote) async throws -> RelayTradePlan {
    guard quote.matches(request), quote.provider == .relay, quote.isFresh(at: .now)
    else { throw WalletFailure("Get a fresh Relay quote before reviewing the trade.") }
    let data = try await LocalBackendClient.post(
      "api/wallet/trade/relay/prepare",
      body: JSONEncoder().encode(request))
    let plan = try JSONDecoder().decode(RelayTradePlan.self, from: data)
    guard plan.request == request, plan.expiry > .now,
      let payer = request.context.sender, plan.from.caseInsensitiveCompare(payer) == .orderedSame,
      plan.token.caseInsensitiveCompare(request.input.address) == .orderedSame,
      QuoteAmount.isPositive(plan.minimumReceive)
    else { throw WalletFailure("The Relay review no longer matches this quote.") }
    return plan
  }

  func submit(_ transaction: WalletSignedTransfer, chain: String) async throws -> WalletTradeStatus {
    try await WalletTransferClient().submit(transaction, chain: chain)
    return .pending
  }
}
