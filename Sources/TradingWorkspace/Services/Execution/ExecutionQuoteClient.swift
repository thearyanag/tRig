import Foundation

@MainActor struct ExecutionQuoteClient {
  func providers() async throws -> [ExecutionProviderInfo] {
    let data = try await LocalBackendClient.get("api/quotes/providers", query: [])
    return try JSONDecoder().decode([ExecutionProviderInfo].self, from: data)
  }
  func quote(_ request: ExecutionQuoteRequest) async throws -> ExecutionQuote {
    let data = try await LocalBackendClient.post(
      "api/quotes/quote", body: JSONEncoder().encode(request))
    return try JSONDecoder().decode(ExecutionQuote.self, from: data)
  }
}
