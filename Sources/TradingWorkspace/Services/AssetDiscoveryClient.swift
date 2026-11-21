import Foundation

@MainActor
struct AssetDiscoveryClient {
  private struct SearchResponse: Decodable { let assets: [Asset] }
  func search(_ query: String, chain: String = "all") async throws -> [Asset] {
    let data = try await LocalBackendClient.get(
      "api/assets/search",
      query: [URLQueryItem(name: "q", value: query), .init(name: "chain", value: chain)])
    return try JSONDecoder().decode(SearchResponse.self, from: data).assets.filter(\.isValid)
  }
  func resolve(_ mint: String, chain: String = "solana") async throws -> Asset {
    let data = try await LocalBackendClient.get(
      "api/assets/resolve",
      query: [URLQueryItem(name: "mint", value: mint), .init(name: "chain", value: chain)])
    let asset = try JSONDecoder().decode(Asset.self, from: data)
    guard asset.isValid, asset.chainID == chain,
      asset.id == (chain == "solana" ? mint : mint.lowercased())
    else {
      throw LocalBackendClient.RequestError(message: "Asset identity could not be confirmed.")
    }
    return asset
  }
}
