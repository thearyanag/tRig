import Foundation

enum WalletTradeOperation: String, Encodable, Sendable {
  case jupiterSwap = "signJupiterSwap"
  case jupiterTriggerAuth = "signJupiterTriggerAuth"
  case jupiterTriggerCancel = "signJupiterTriggerCancel"
  case jupiterTriggerTransfer = "signJupiterTriggerTransfer"
  case relayEVM = "signRelayEVM"
  case relaySolana = "signRelaySolana"
  case flashOrder = "signFlashOrder"
  case flashCancel = "signFlashCancel"
  case flashApproval = "signFlashApproval"
  case flashSolanaSetup = "signFlashSolanaSetup"

  var fundingFamily: WalletFamily? {
    switch self {
    case .jupiterSwap, .jupiterTriggerAuth, .jupiterTriggerCancel, .jupiterTriggerTransfer,
      .relaySolana, .flashSolanaSetup: .solana
    case .relayEVM, .flashApproval: .evm
    case .flashOrder, .flashCancel: nil
    }
  }
}

enum WalletTradeProvider: String, Codable, Sendable {
  case jupiter, jupiterTrigger, relay, relayApproval, flashApproval

  var displayName: String {
    switch self {
    case .jupiter: "Jupiter"
    case .jupiterTrigger: "Jupiter Trigger"
    case .relay, .relayApproval: "Relay"
    case .flashApproval: "Definitive Flash"
    }
  }
}

enum WalletTradeStatus: String, Codable, Sendable {
  case pending, confirmed, failed, expired

  var label: String { rawValue.capitalized }
}

struct WalletTradeDetails: Codable, Sendable {
  let provider: WalletTradeProvider
  let title: String
  let chain: String
  let requestID: String
  var expiresAt: Date? = nil
  var lastValidBlockHeight: UInt64? = nil
}

struct WalletTradeActivity: Codable, Identifiable, Sendable {
  let details: WalletTradeDetails
  let walletID: UUID
  let address: String
  let transactionID: String
  let createdAt: Date
  var status: WalletTradeStatus

  var id: String { "\(details.chain):\(transactionID)" }
}

struct WalletActivityItem: Identifiable {
  let id: String
  let title: String
  let source: String
  let chain: String
  let date: Date
  let status: WalletTradeStatus
  let transactionID: String

  init(transfer: WalletTransferActivity) {
    id = "\(transfer.intent.chain):\(transfer.id)"
    title = "Send \(transfer.intent.amount) \(transfer.symbol)"
    source = transfer.network
    chain = transfer.intent.chain
    date = transfer.createdAt
    status = WalletTradeStatus(rawValue: transfer.status.rawValue) ?? .pending
    transactionID = transfer.id
  }

  init(trade: WalletTradeActivity) {
    id = trade.id
    title = trade.details.title
    source = trade.details.provider.displayName
    chain = trade.details.chain
    date = trade.createdAt
    status = trade.status
    transactionID = trade.transactionID
  }
}
