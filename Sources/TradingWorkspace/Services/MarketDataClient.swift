import Foundation

@MainActor struct MarketDataClient {
  private func query(_ asset: Asset) -> [URLQueryItem] {
    [
      .init(name: "chain", value: asset.chainID), .init(name: "address", value: asset.id),
      .init(name: "pool", value: asset.pool),
    ]
  }
  func snapshot(_ asset: Asset) async throws -> MarketSnapshot {
    let data = try await LocalBackendClient.get("api/markets/snapshot", query: query(asset))
    return try JSONDecoder().decode(MarketSnapshot.self, from: data)
  }
  func trades(_ asset: Asset) async throws -> RecentTrades {
    let data = try await LocalBackendClient.get("api/markets/trades", query: query(asset))
    return try JSONDecoder().decode(RecentTrades.self, from: data)
  }
}
