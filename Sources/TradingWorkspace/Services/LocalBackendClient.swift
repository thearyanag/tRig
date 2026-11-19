import Foundation

@MainActor
struct LocalBackendClient {
  private struct Failure: Decodable { let error: String }
  struct RequestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }
  static func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
    let backend = ChartBackend.shared
    backend.start()
    var base = backend.baseURL
    for _ in 0..<150 where base == nil {
      try Task.checkCancellation()
      if let error = backend.error { throw RequestError(message: error) }
      try await Task.sleep(for: .milliseconds(100))
      base = backend.baseURL
    }
    guard let base else {
      throw RequestError(message: "The local service is not ready. Try again.")
    }
    var url = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    url.queryItems = query
    let request = URLRequest(
      url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
    let (data, response) = try await URLSession.shared.data(for: request)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else {
      throw RequestError(message: "Invalid service response.")
    }
    guard http.statusCode == 200 else {
      throw RequestError(
        message: (try? JSONDecoder().decode(Failure.self, from: data).error)
          ?? "Request unavailable. Try again.")
    }
    return data
  }
}
