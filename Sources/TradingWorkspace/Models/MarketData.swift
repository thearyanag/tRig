import Foundation

struct MarketNetwork: Decodable, Identifiable, Sendable {
  let id: String
  let name: String
  let vm: String
  let geckoId: String?
  let explorerUrl: String?
  let marketQuotes: Bool
  let conditionalQuotes: Bool
  let nativeToken: MarketCurrency?
}
struct MarketSnapshot: Decodable, Sendable {
  var rangeLoading: Bool? = nil
  let chain: String
  let address: String
  let pool: String
  let asset: Asset
  let high24h: Double?
  let low24h: Double?
  let rangeStart: Double
  let rangeEnd: Double
  let links: [AssetLink]
  let fetchedAt: Double
  let warning: String?
  func matches(_ input: Asset) -> Bool {
    chain == input.chainID && address == (input.isSolana ? input.id : input.id.lowercased())
      && pool == (input.isSolana ? input.pool : input.pool.lowercased())
  }
}
struct AssetLink: Decodable, Identifiable, Sendable {
  let title: String
  let url: String
  var id: String { url }
  var destination: URL? {
    guard let result = URL(string: url), result.scheme == "https" else { return nil }
    return result
  }
}
struct RecentTrade: Decodable, Identifiable, Sendable {
  let id: String
  let side: String
  let priceUsd: String
  let quantity: String
  let valueUsd: String
  let timestamp: String
  let transaction: String
  var date: Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: timestamp) { return date }
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.date(from: timestamp)
  }
}
struct RecentTrades: Decodable, Sendable {
  let chain: String
  let address: String
  let pool: String
  let rows: [RecentTrade]
  let fetchedAt: Double
  let warning: String?
  func matches(_ input: Asset) -> Bool {
    chain == input.chainID && address == (input.isSolana ? input.id : input.id.lowercased())
      && pool == (input.isSolana ? input.pool : input.pool.lowercased())
  }
}
