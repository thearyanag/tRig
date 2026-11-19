import Foundation

@MainActor
struct AssetDiscoveryClient {
  private struct SearchResponse: Decodable { let assets: [Asset] }
  func search(_ query: String) async throws -> [Asset] {
    let data = try await LocalBackendClient.get(
      "api/assets/search", query: [URLQueryItem(name: "q", value: query)])
    return try JSONDecoder().decode(SearchResponse.self, from: data).assets.filter(\.isValid)
  }
  func resolve(_ mint: String) async throws -> Asset {
    let data = try await LocalBackendClient.get(
      "api/assets/resolve", query: [URLQueryItem(name: "mint", value: mint)])
    let asset = try JSONDecoder().decode(Asset.self, from: data)
    guard asset.isValid, asset.id == mint else {
      throw LocalBackendClient.RequestError(message: "Asset identity could not be confirmed.")
    }
    return asset
  }
}
