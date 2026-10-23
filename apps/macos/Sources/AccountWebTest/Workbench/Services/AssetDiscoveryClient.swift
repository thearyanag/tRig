import Foundation

@MainActor
struct AssetDiscoveryClient {
  private struct SearchResponse: Decodable { let assets: [Asset] }
  private struct Failure: Decodable { let error: String }
  struct RequestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  func search(_ query: String) async throws -> [Asset] {
    let data = try await request("api/assets/search", query: "q", value: query)
    return try JSONDecoder().decode(SearchResponse.self, from: data).assets.filter(\.isValid)
  }
  func resolve(_ mint: String) async throws -> Asset {
    let data = try await request("api/assets/resolve", query: "mint", value: mint)
    let asset = try JSONDecoder().decode(Asset.self, from: data)
    guard asset.isValid, asset.id == mint else {
      throw RequestError(message: "Asset identity could not be confirmed.")
    }
    return asset
  }
  private func request(_ path: String, query: String, value: String) async throws -> Data {
    let backend = ChartBackend.shared
    backend.start()
    var base = backend.baseURL
    for _ in 0..<150 where base == nil {
      try Task.checkCancellation()
      if let error = backend.error { throw RequestError(message: error) }
      try await Task.sleep(for: .milliseconds(100))
      base = backend.baseURL
    }
    guard let base else { throw RequestError(message: "Asset search is not ready. Try again.") }
    var url = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    url.queryItems = [URLQueryItem(name: query, value: value)]
    let request = URLRequest(
      url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
    let (data, response) = try await URLSession.shared.data(for: request)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else {
      throw RequestError(message: "Search returned an invalid response.")
    }
    guard http.statusCode == 200 else {
      throw RequestError(
        message: (try? JSONDecoder().decode(Failure.self, from: data).error)
          ?? "Asset search is unavailable. Try again.")
    }
    return data
  }
}
