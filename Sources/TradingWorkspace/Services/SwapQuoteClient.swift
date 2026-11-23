import Foundation

@MainActor
struct SwapQuoteClient {
  func fetch(_ input: SwapQuoteInput) async throws -> SwapQuote {
    let data = try await LocalBackendClient.get(
      "api/swap/quote",
      query: [
        URLQueryItem(name: "assetMint", value: input.assetMint),
        URLQueryItem(name: "side", value: input.side),
        URLQueryItem(name: "amount", value: input.amount),
        URLQueryItem(name: "slippageBps", value: String(input.slippageBps)),
      ])
    return try JSONDecoder().decode(SwapQuote.self, from: data)
  }
}
