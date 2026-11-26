import Foundation

struct WalletTransferIntent: Codable, Equatable, Sendable {
  let chain: String
  let from: String
  let to: String
  let amount: String
  let tokenAddress: String?

  init(chain: String, from: String, to: String, amount: String, tokenAddress: String? = nil) {
    self.chain = chain
    self.from = from
    self.to = to
    self.amount = amount
    self.tokenAddress = tokenAddress
  }

  func atomicUnits(decimals: Int) -> String? {
    guard (0...255).contains(decimals), QuoteAmount.isPositive(amount) else { return nil }
    let parts = amount.split(separator: ".", omittingEmptySubsequences: false)
    let fractional = parts.count == 2
      ? String(parts[1].reversed().drop(while: { $0 == "0" }).reversed()) : ""
    guard fractional.count <= decimals else { return nil }
    let value = parts[0] + fractional + String(repeating: "0", count: decimals - fractional.count)
    return String(value.drop(while: { $0 == "0" }))
  }

  func matches(_ other: Self, decimals: Int) -> Bool {
    guard chain == other.chain else { return false }
    func address(_ value: String?) -> String? { chain == "solana" ? value : value?.lowercased() }
    return address(from) == address(other.from) && address(to) == address(other.to)
      && address(tokenAddress) == address(other.tokenAddress)
      && atomicUnits(decimals: decimals) == other.atomicUnits(decimals: decimals)
  }
}

struct WalletTransferPlan: Codable, Sendable {
  struct Parameters: Codable, Sendable {
    struct SPL: Codable, Sendable {
      enum Program: String, Codable, Sendable {
        case legacy
        case token2022
      }

      struct Source: Codable, Sendable {
        let address: String
        let amount: UInt64
      }

      let program: Program
      let decimals: Int
      let sources: [Source]
      let createRecipientAccount: Bool
    }

    let family: WalletFamily
    let blockhash: String?
    let lastValidBlockHeight: UInt64?
    let spl: SPL?
    let chainId: String?
    let nonce: String?
    let gasPrice: String?
    let gasLimit: String?
  }

  let intent: WalletTransferIntent
  let amountAtomic: String
  let decimals: Int
  let fee: String
  let feeDecimals: Int
  let accountCreationFee: String?
  let expiresAt: Double
  let parameters: Parameters

  var expired: Bool { Date.now.timeIntervalSince1970 >= expiresAt }
}

struct WalletSignedTransfer: Decodable, Sendable {
  let signed: String
  let transactionId: String
}

struct WalletTransferActivity: Codable, Identifiable, Sendable {
  enum Status: String, Codable, Sendable {
    case pending, confirmed, failed

    var title: String { rawValue.capitalized }
  }

  let id: String
  let intent: WalletTransferIntent
  let network: String
  let symbol: String
  let createdAt: Date
  var status: Status
  let lastValidBlockHeight: UInt64?
}

@MainActor
struct WalletTransferClient {
  private struct Submission: Encodable {
    let chain: String
    let signed: String
    let transactionId: String
  }

  private struct Receipt: Decodable { let transactionId: String }
  private struct StatusResponse: Decodable { let status: WalletTransferActivity.Status }

  func prepare(_ intent: WalletTransferIntent) async throws -> WalletTransferPlan {
    let data = try await LocalBackendClient.post("api/wallet/transfer/prepare",
      body: JSONEncoder().encode(intent))
    let plan = try JSONDecoder().decode(WalletTransferPlan.self, from: data)
    guard plan.intent == intent else { throw WalletFailure("The review does not match this transfer.") }
    return plan
  }

  func submit(_ transaction: WalletSignedTransfer, chain: String) async throws {
    let payload = Submission(chain: chain, signed: transaction.signed, transactionId: transaction.transactionId)
    let data = try await LocalBackendClient.post("api/wallet/transfer/submit",
      body: JSONEncoder().encode(payload))
    let receipt = try JSONDecoder().decode(Receipt.self, from: data)
    guard receipt.transactionId == transaction.transactionId else {
      throw WalletFailure("The network returned a different transaction ID.")
    }
  }

  func status(for activity: WalletTransferActivity) async throws -> WalletTransferActivity.Status {
    var query: [URLQueryItem] = [
      .init(name: "chain", value: activity.intent.chain),
      .init(name: "transactionId", value: activity.id),
    ]
    if let height = activity.lastValidBlockHeight {
      query.append(.init(name: "lastValidBlockHeight", value: String(height)))
    }
    let data = try await LocalBackendClient.get("api/wallet/transfer/status", query: query)
    return try JSONDecoder().decode(StatusResponse.self, from: data).status
  }
}
