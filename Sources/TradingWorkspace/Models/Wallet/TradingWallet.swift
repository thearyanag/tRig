import Foundation

enum WalletFamily: String, Codable, CaseIterable, Identifiable, Sendable {
  case solana, evm

  var id: Self { self }
  var title: String { self == .solana ? "Solana" : "EVM" }
  var symbol: String { self == .solana ? "solana" : "ethereum" }
}

struct WalletAccount: Codable, Equatable, Hashable, Identifiable, Sendable {
  let family: WalletFamily
  let address: String

  var id: String { "\(family.rawValue):\(identityAddress)" }
  var identityAddress: String { family == .solana ? address : address.lowercased() }
  var shortAddress: String { "\(address.prefix(6))…\(address.suffix(4))" }
  var receiveURI: String { "\(family.symbol):\(address)" }
}

struct TradingWallet: Codable, Equatable, Identifiable {
  let id: UUID
  let label: String
  let accounts: [WalletAccount]
  let source: WalletSecret.Kind

  var addressAccounts: [WalletAccount] {
    WalletFamily.allCases.compactMap { family in accounts.first { $0.family == family } }
  }
}

struct WalletSecret: Codable, Sendable {
  enum Kind: String, Codable, Sendable { case phrase, privateKey }

  let kind: Kind
  let value: String
  var family: WalletFamily?
  var passphrase: String?
  var accountIndex: UInt32?
}

struct WalletFailure: LocalizedError {
  let errorDescription: String?

  init(_ message: String) { errorDescription = message }
}
