import Foundation

struct WalletHoldingToken: Decodable, Sendable {
  let address: String?
  let marketMint: String?
  let name: String
  let symbol: String
  let quantity: String
  let decimals: Int
  let imageUrl: String?
  let priceUsd: String?
}

struct WalletHoldingsSnapshot: Decodable, Sendable {
  let chain: String
  let address: String
  let tokens: [WalletHoldingToken]
  let warnings: [String]
  let asOf: Double
}

@MainActor
struct WalletHoldingsClient {
  func holdings(network: WalletNetwork, account: WalletAccount) async throws -> WalletHoldingsSnapshot {
    let data = try await LocalBackendClient.get("api/wallet/holdings", query: [
      .init(name: "chain", value: network.id), .init(name: "address", value: account.address),
    ])
    let snapshot = try JSONDecoder().decode(WalletHoldingsSnapshot.self, from: data)
    guard snapshot.chain == network.id,
      WalletAccount(family: account.family, address: snapshot.address).id == account.id
    else {
      throw WalletFailure("Wallet holdings did not match the selected account.")
    }
    return snapshot
  }
}
