import Foundation

struct WalletNetwork: Decodable, Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let family: WalletFamily
  let symbol: String
  let decimals: Int

  static let solana = WalletNetwork(id: "solana", name: "Solana", family: .solana, symbol: "SOL", decimals: 9)

  func accepts(_ address: String) -> Bool {
    Asset.validAddress(address, chain: id)
  }
}

@MainActor
struct WalletNetworkClient {
  struct Balance: Decodable, Sendable {
    let amount: String
    let asOf: Date

    private enum CodingKeys: String, CodingKey { case amount, asOf }

    init(from decoder: any Decoder) throws {
      let box = try decoder.container(keyedBy: CodingKeys.self)
      amount = try box.decode(String.self, forKey: .amount)
      asOf = try Date(timeIntervalSince1970: box.decode(Double.self, forKey: .asOf))
    }
  }

  func networks() async throws -> [WalletNetwork] {
    let data = try await LocalBackendClient.get("api/wallet/networks", query: [])
    return try JSONDecoder().decode([WalletNetwork].self, from: data)
  }

  func balance(network: WalletNetwork, account: WalletAccount) async throws -> Balance {
    let data = try await LocalBackendClient.get("api/wallet/balance", query: [
      .init(name: "chain", value: network.id), .init(name: "address", value: account.address),
    ])
    return try JSONDecoder().decode(Balance.self, from: data)
  }
}
