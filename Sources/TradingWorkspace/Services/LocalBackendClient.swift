import Foundation

@MainActor
struct LocalBackendClient {
  private struct Failure: Decodable { let error: String }
  struct RequestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }
  static func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
    try await request(path, query: query, body: nil)
  }
  static func post(_ path: String, body: Data) async throws -> Data {
    try await request(path, query: [], body: body)
  }
  private static func request(_ path: String, query: [URLQueryItem], body: Data?) async throws
    -> Data
  {
    let base = try await LocalDataService.shared.readyURL()
    var url = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    url.queryItems = query
    var request = URLRequest(
      url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
    if let body {
      request.httpMethod = "POST"
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
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
