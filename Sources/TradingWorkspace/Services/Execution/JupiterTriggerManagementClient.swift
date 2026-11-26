import Foundation

struct JupiterTriggerTransferPlan: Codable, Sendable {
  let wallet: String
  let vault: String
  let mint: String
  let amount: String
  let transaction: String
  let expiresAt: UInt64
  let direction: String
  let orderTokenAccount: String
  let decimals: Int
  let feeLamports: UInt64
  let rentLamports: UInt64

  var expiry: Date { Date(timeIntervalSince1970: Double(expiresAt)) }
}

struct JupiterTriggerOrder: Decodable, Identifiable, Sendable {
  let id: String
  let orderType: String
  let orderState: String
  let rawState: String?
  let inputMint: String
  let outputMint: String
  let initialInputAmount: String
  let remainingInputAmount: String
  let outputAmount: String?
  let triggerCondition: String?
  let triggerPriceUsd: String?
  let tpPriceUsd: String?
  let slPriceUsd: String?
  let inputDecimals: Int?
  let canCancel: Bool

  var name: String {
    switch orderType {
    case "single": "Price order"
    case "oco": "TP/SL"
    case "otoco": "Entry + TP/SL"
    default: "Trigger order"
    }
  }

  var needsWithdrawal: Bool {
    rawState == "ready_to_cancel" || orderState == "pending_withdraw" || orderState == "expired"
  }

  var status: String {
    switch orderState {
    case "pending": "Deposit pending"
    case "open": "Open"
    case "executing": rawState == "partial_fill_success" ? "Partially filled" : "Executing"
    case "filled": "Filled"
    case "pending_withdraw": "Withdrawal required"
    case "cancelled": "Cancelled"
    case "expired": "Expired"
    case "failed": "Failed"
    default: "Unknown"
    }
  }

  var pair: String { "\(Self.tokenLabel(inputMint)) → \(Self.tokenLabel(outputMint))" }

  var amount: String {
    Self.formattedAmount(initialInputAmount, mint: inputMint, decimals: inputDecimals)
  }

  var price: String? {
    func usd(_ value: String) -> String {
      PortfolioFormat.currency(value, price: true)
    }
    if let tpPriceUsd, let slPriceUsd { return "TP \(usd(tpPriceUsd)) · SL \(usd(slPriceUsd))" }
    guard let triggerPriceUsd else { return nil }
    let target = usd(triggerPriceUsd)
    return triggerCondition.map { "\($0.capitalized) \(target)" } ?? target
  }

  static func tokenLabel(_ mint: String) -> String {
    switch mint {
    case Asset.solana.id: "SOL"
    case SwapQuoteInput.usdc: "USDC"
    default: "\(mint.prefix(4))…\(mint.suffix(4))"
    }
  }

  static func formattedAmount(_ amount: String, mint: String, decimals: Int?) -> String {
    let precision = decimals ?? (mint == Asset.solana.id ? 9 : mint == SwapQuoteInput.usdc ? 6 : nil)
    guard let precision else { return "\(amount) base units" }
    return "\(JupiterSwapPlan.units(amount, decimals: precision)) \(tokenLabel(mint))"
  }
}

struct JupiterTriggerOrderPage: Decodable, Sendable {
  let orders: [JupiterTriggerOrder]
  let nextOffset: Int?
}

struct JupiterTriggerWithdrawalPlan: Decodable, Sendable {
  let planId: String
  let signingPlan: JupiterTriggerTransferPlan
  let feeLamports: String
  let rentLamports: String
  let mintDecimals: Int
  let lastValidBlockHeight: UInt64?
}

@MainActor
struct JupiterTriggerManagementClient {
  private struct OrderRequest: Encodable {
    let wallet: String
    let orderId: String
  }

  private struct CancelChallenge: Codable, Sendable {
    let wallet: String
    let orderId: String
    let nonce: String
    let expiresAt: UInt64

    var expiry: Date { Date(timeIntervalSince1970: Double(expiresAt)) }
  }

  private struct Prepare: Encodable {
    let wallet: String
    let orderId: String
    let signature: String
  }

  private struct Submission: Encodable {
    let wallet: String
    let planId: String
    let signed: String
    let transactionId: String
  }

  private struct Receipt: Decodable {
    let orderId: String
    let transactionId: String
    let confirmed: Bool
  }

  func orders(account: WalletAccount, offset: Int) async throws -> JupiterTriggerOrderPage {
    try await JupiterTriggerAPI.get("orders", query: [
      URLQueryItem(name: "wallet", value: account.address),
      URLQueryItem(name: "offset", value: String(offset)),
    ])
  }

  func withdraw(
    _ order: JupiterTriggerOrder, walletStore: WalletStore, wallet: TradingWallet, account: WalletAccount
  ) async throws -> JupiterTriggerWithdrawalPlan {
    try await JupiterTriggerSession().authenticate(walletStore: walletStore, wallet: wallet, account: account)
    try await walletStore.unlock()
    let challenge: CancelChallenge = try await JupiterTriggerAPI.post(
      "cancel/challenge", OrderRequest(wallet: account.address, orderId: order.id))
    guard challenge.wallet == account.address, challenge.orderId == order.id, challenge.expiry > .now else {
      throw WalletFailure("Jupiter returned an expired or mismatched cancellation request.")
    }

    let review: JupiterTriggerWithdrawalPlan = try await walletStore.authorizeTrade(
      operation: .jupiterTriggerCancel, plan: challenge, wallet: wallet, account: account,
      expiresAt: challenge.expiry
    ) { signed in
      try await JupiterTriggerAPI.post(
        "cancel/prepare", Prepare(wallet: account.address, orderId: order.id, signature: signed.signed))
    }
    let plan = review.signingPlan
    guard plan.direction == "withdrawal", plan.wallet == account.address, plan.mint == order.inputMint,
      plan.expiry > .now, (1...128).contains(review.planId.utf8.count),
      let amount = UInt64(plan.amount), let remaining = UInt64(order.remainingInputAmount),
      amount > 0, amount <= remaining,
      (0...255).contains(review.mintDecimals), plan.decimals == review.mintDecimals,
      UInt64(review.feeLamports) == plan.feeLamports,
      UInt64(review.rentLamports) == plan.rentLamports
    else { throw WalletFailure("The withdrawal review does not match this order and wallet.") }
    return review
  }

  func submit(
    _ signed: WalletSignedTransfer, order: JupiterTriggerOrder, review: JupiterTriggerWithdrawalPlan
  ) async throws -> WalletTradeStatus {
    let receipt: Receipt = try await JupiterTriggerAPI.post(
      "cancel/submit", Submission(wallet: review.signingPlan.wallet, planId: review.planId,
        signed: signed.signed, transactionId: signed.transactionId))
    guard receipt.orderId == order.id, receipt.transactionId == signed.transactionId else {
      throw WalletFailure("The withdrawal receipt does not match the signed transaction.")
    }
    return receipt.confirmed ? .confirmed : .pending
  }
}
