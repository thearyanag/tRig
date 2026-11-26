import Foundation

struct JupiterPriceOrderIntent: Encodable, Equatable, Sendable {
  enum Condition: String, Encodable, Sendable {
    case above, below
  }

  let wallet: String
  let inputMint: String
  let outputMint: String
  let inputAmount: String
  let inputDecimals: Int
  let triggerMint: String
  let triggerCondition: Condition
  let triggerPriceUsd: String
  let slippageBps: Int

  init?(asset: Asset, request: ExecutionQuoteRequest, account: WalletAccount) {
    guard asset.isSolana, account.family == .solana, request.isValid,
      request.input.chain == "solana", request.output.chain == "solana",
      request.orderType == .limit || request.orderType == .stopLoss,
      let settlement = asset.settlement, let side = request.side,
      side == "buy" || side == "sell",
      side == "sell" || request.orderType == .limit
    else { return nil }
    let buy = side == "buy"
    let price = request.orderType == .stopLoss ? request.triggerPriceUsd : request.limitPriceUsd
    guard let price, QuoteAmount.isPositive(price),
      request.input.address == (buy ? settlement.address : asset.id),
      request.output.address == (buy ? asset.id : settlement.address),
      let decimals = buy ? settlement.decimals : asset.decimals,
      let atomic = WalletTransferIntent(
        chain: "solana", from: account.address, to: "", amount: request.amount
      ).atomicUnits(decimals: decimals),
      let units = UInt64(atomic), units > 0
    else { return nil }
    wallet = account.address
    inputMint = request.input.address
    outputMint = request.output.address
    inputAmount = String(units)
    inputDecimals = decimals
    triggerMint = asset.id
    triggerCondition = buy || request.orderType == .stopLoss ? .below : .above
    triggerPriceUsd = price
    slippageBps = request.slippageBps
  }
}

struct JupiterTriggerDepositReview: Decodable, Sendable {
  let planId: String
  let signingPlan: JupiterTriggerTransferPlan
  let feeLamports: String
  let rentLamports: String
  let mintDecimals: Int
  let orderExpiresAt: UInt64
  let lastValidBlockHeight: UInt64?

  var expiry: Date { signingPlan.expiry }
  var orderExpiry: Date { Date(timeIntervalSince1970: Double(orderExpiresAt)) }

  func matches(_ intent: JupiterPriceOrderIntent, now: Date = .now) -> Bool {
    signingPlan.direction == "deposit" && signingPlan.wallet == intent.wallet
      && signingPlan.mint == intent.inputMint && signingPlan.amount == intent.inputAmount
      && signingPlan.decimals == intent.inputDecimals && mintDecimals == intent.inputDecimals
      && Asset.validAddress(signingPlan.vault, chain: "solana") && signingPlan.vault != intent.wallet
      && UInt64(feeLamports) == signingPlan.feeLamports
      && UInt64(rentLamports) == signingPlan.rentLamports
      && !planId.isEmpty && expiry > now && orderExpiry > expiry
  }
}

@MainActor
struct JupiterTriggerOrderClient {
  private struct Submission: Encodable {
    let wallet: String
    let planId: String
    let signed: String
    let transactionId: String
  }

  struct Receipt: Decodable, Sendable {
    let orderId: String
    let transactionId: String
    let confirmed: Bool
  }

  func prepare(_ intent: JupiterPriceOrderIntent) async throws -> JupiterTriggerDepositReview {
    let review: JupiterTriggerDepositReview = try await JupiterTriggerAPI.post("prepare", intent)
    guard review.matches(intent) else {
      throw WalletFailure("The Jupiter deposit differs from this order. Refresh the review.")
    }
    return review
  }

  func submit(_ signed: WalletSignedTransfer, review: JupiterTriggerDepositReview) async throws -> Receipt {
    let input = Submission(
      wallet: review.signingPlan.wallet, planId: review.planId,
      signed: signed.signed, transactionId: signed.transactionId)
    let receipt: Receipt = try await JupiterTriggerAPI.post("submit", input)
    guard receipt.transactionId == signed.transactionId, !receipt.orderId.isEmpty else {
      throw WalletFailure("Check for this deposit in Orders and Activity.")
    }
    return receipt
  }
}
