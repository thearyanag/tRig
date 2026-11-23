import Foundation

enum ExecutionProvider: String, Codable, CaseIterable, Identifiable, Sendable {
  case jupiter, relay, flash
  var id: Self { self }
  var name: String {
    switch self {
    case .jupiter: "Jupiter"
    case .relay: "Relay"
    case .flash: "Definitive Flash"
    }
  }
}
enum ExecutionOrderType: String, Codable, CaseIterable, Identifiable, Sendable {
  case market, limit
  case stopLoss = "stop-loss"
  var id: Self { self }
  var name: String {
    switch self {
    case .market: "Market"
    case .limit: "Limit"
    case .stopLoss: "Stop-loss"
    }
  }
}
struct ExecutionTokenRef: Codable, Hashable, Sendable {
  var chain: String
  var address: String
}
struct ExecutionQuoteContext: Codable, Hashable, Sendable {
  var sender: String?
  var recipient: String?
}
struct ExecutionQuoteRequest: Codable, Hashable, Sendable {
  var provider: ExecutionProvider?
  var side: String? = nil
  var input: ExecutionTokenRef
  var output: ExecutionTokenRef
  var amount: String
  var orderType: ExecutionOrderType
  var slippageBps: Int
  var limitPriceUsd: String?
  var triggerPriceUsd: String?
  var context: ExecutionQuoteContext
  var isValid: Bool {
    guard input != output, !input.chain.isEmpty, !output.chain.isEmpty,
      !input.address.isEmpty, !output.address.isEmpty, QuoteAmount.isPositive(amount),
      (1...500).contains(slippageBps)
    else { return false }
    if orderType != .market && input.chain != output.chain { return false }
    if orderType == .stopLoss && side == "buy" { return false }
    return orderType == .market
      || QuoteAmount.isPositive(orderType == .limit ? limitPriceUsd ?? "" : triggerPriceUsd ?? "")
  }
}
struct ExecutionToken: Decodable, Sendable {
  let chain: String
  let address: String
  let symbol: String
  let decimals: Int?
}
struct ExecutionChain: Decodable, Identifiable, Sendable {
  let id: String
  let name: String
  let vm: String
  let providerId: String
  let enabled: Bool
  let depositEnabled: Bool
  let nativeToken: ExecutionToken?
  let minimumOrderUsd: String?
}
struct ExecutionProviderInfo: Decodable, Identifiable, Sendable {
  let id: ExecutionProvider
  let name: String
  let configured: Bool
  let orderTypes: [ExecutionOrderType]
  let chains: [ExecutionChain]
  let metadataSource: String
  let metadataAsOf: Double
  let warning: String?
  let senderRequired: Bool
  let senderRequiredCrossChain: Bool
  let recipientRequiredCrossChain: Bool
}
struct ExecutionFee: Decodable, Sendable {
  let kind: String
  let amountUsd: String?
  let amount: String?
  let token: ExecutionToken?
  let rateBps: Int?
  let includedInQuote: Bool
}
struct ExecutionQuote: Decodable, Identifiable, Sendable {
  let provider: ExecutionProvider
  let providerName: String
  let providerQuoteId: String?
  let input: ExecutionToken
  let output: ExecutionToken
  let orderType: ExecutionOrderType
  let requestedAmount: String
  let payAmount: String
  let receiveAmount: String
  let minimumReceive: String?
  let slippageBps: Int
  let priceImpactPercent: String?
  let fees: [ExecutionFee]
  let routes: [String]
  let fetchedAt: Double
  let expiresAt: Double
  let expiryKind: String
  let indicative: Bool
  let warnings: [String]
  let request: ExecutionQuoteRequest
  var id: String { "\(provider.rawValue):\(providerQuoteId ?? ""):\(fetchedAt)" }
  func matches(_ input: ExecutionQuoteRequest) -> Bool {
    request == input && orderType == input.orderType && requestedAmount == input.amount
      && self.input.chain == input.input.chain && output.chain == input.output.chain
      && Self.sameAddress(self.input.address, input.input.address, chain: self.input.chain)
      && Self.sameAddress(output.address, input.output.address, chain: output.chain)
      && (input.provider == nil || input.provider == provider)
      && expiresAt > fetchedAt && Date().timeIntervalSince1970 >= fetchedAt - 5
  }
  func isFresh(at date: Date) -> Bool { date.timeIntervalSince1970 < expiresAt }
  private static func sameAddress(_ a: String, _ b: String, chain: String) -> Bool {
    chain.hasPrefix("eip155:") || chain.hasPrefix("flash:")
      ? a.lowercased() == b.lowercased() : a == b
  }
}
