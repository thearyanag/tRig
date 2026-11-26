import Foundation

struct FlashOrder: Decodable, Identifiable, Sendable {
  let orderId: String
  let orderType: String
  let side: String
  let status: String
  let chain: String
  let asset: String
  let spendAsset: String
  let quantity: String
  let price: String?
  let canCancel: Bool
  let placedAt: String
  let filledQuantity: String?

  var id: String { orderId }
  var typeLabel: String { orderType.replacingOccurrences(of: "-", with: " ").capitalized }
}

struct FlashOrderPage: Decodable, Sendable {
  let orders: [FlashOrder]
  let nextPageToken: String?
}

struct FlashCancelPlan: Encodable, Sendable {
  let orderId: String
  let funder: String
  let family: WalletFamily
}

struct FlashOrderSignPlan: Codable, Sendable {
  let planId: String
  let chainId: UInt64?
  let funder: String
  let fromToken: String
  let toToken: String
  let fromAmount: String
  let orderDeadline: UInt64
  let expiresAt: UInt64
  let typedData: String?
  let orderMessage: String?
  let nonce: String?
  let tradingGroup: String?
  let inputProgram: String?
  let outputProgram: String?

  var chain: String { chainId.map { "eip155:\($0)" } ?? "solana" }
  var expiry: Date { Date(timeIntervalSince1970: Double(expiresAt)) }
  var orderExpiry: Date { Date(timeIntervalSince1970: Double(orderDeadline)) }
}

struct FlashOrderReview: Decodable, Sendable {
  let signPlan: FlashOrderSignPlan
  let orderType: String
  let receiveAmount: String
  let feeUsd: String
  let availableAmount: String
  let spendDecimals: Int
  let approval: FlashAllowanceReview?
  let solanaSetup: FlashSolanaSetupPlan?
}

struct FlashSolanaSetupPlan: Codable, Sendable {
  struct Setup: Codable, Sendable {
    let funder: String
    let inputMint: String
    let outputMint: String
    let amount: String
    let decimals: Int
    let blockhash: String
    let createInput: Bool
    let createOutput: Bool
    let delegate: Bool
    let wrap: Bool
  }
  let planId: String
  let setup: Setup
  let expiresAt: UInt64
  let lastValidBlockHeight: UInt64
  let feeLamports: UInt64
  let rentLamports: UInt64

  var expiry: Date { Date(timeIntervalSince1970: Double(expiresAt)) }
  var feeSOL: String { sol(feeLamports) }
  var rentSOL: String { sol(rentLamports) }
  var newAccounts: Int { (setup.createInput ? 1 : 0) + (setup.createOutput ? 1 : 0) }

  private func sol(_ lamports: UInt64) -> String {
    NSDecimalNumber(decimal: Decimal(lamports) / 1_000_000_000).stringValue + " SOL"
  }
}

struct FlashAllowanceReview: Decodable, Sendable {
  static let settlement = "0x5d00000873b6BF41539e6f5365B0Ff7d3c368f78"

  let plan: FlashAllowancePlan
  let spender: String
  let feeNative: String
  let feeSymbol: String
}

struct FlashAllowancePlan: Codable, Sendable {
  let planId: String
  let chainId: UInt64
  let funder: String
  let token: String
  let amount: String
  let nonce: String
  let gasPrice: String
  let gasLimit: String
  let fee: String
  let expiresAt: UInt64

  var expiry: Date { Date(timeIntervalSince1970: Double(expiresAt)) }
}

struct FlashOrderAcknowledgement: Decodable, Sendable {
  let orderId: String
}

struct FlashOrderClient {
  private struct CancelRequest: Encodable {
    let orderId: String
    let funder: String
    let family: WalletFamily
    let signature: String
  }

  private struct PrepareRequest: Encodable {
    let request: ExecutionQuoteRequest
    let funder: String
    let takeProfit: Bool
  }

  private struct SubmitRequest: Encodable {
    let planId: String
    let signature: String
  }

  private struct ApprovalSubmission: Encodable {
    let planId: String
    let signed: String
    let transactionId: String
  }

  private struct ApprovalReceipt: Decodable {
    let transactionId: String
  }

  func list(account: WalletAccount, pageToken: String? = nil) async throws -> FlashOrderPage {
    var query = [
      URLQueryItem(name: "funder", value: account.address),
      URLQueryItem(name: "family", value: account.family.rawValue),
    ]
    if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
    let data = try await LocalBackendClient.get("api/flash/orders", query: query)
    return try JSONDecoder().decode(FlashOrderPage.self, from: data)
  }

  func cancel(plan: FlashCancelPlan, signature: WalletSignedTransfer) async throws -> FlashOrder {
    guard signature.transactionId == plan.orderId else { throw WalletFailure("This signature is for a different order.") }
    let result: FlashOrder = try await post(
      "cancel",
      CancelRequest(orderId: plan.orderId, funder: plan.funder, family: plan.family, signature: signature.signed))
    guard result.id == plan.orderId else { throw WalletFailure("Refresh Orders to check cancellation.") }
    return result
  }

  func prepare(_ request: ExecutionQuoteRequest, account: WalletAccount, takeProfit: Bool)
    async throws -> FlashOrderReview {
    guard request.input.chain == request.output.chain,
      (account.family == .solana && request.input.chain == "solana")
        || (account.family == .evm && request.input.chain.hasPrefix("eip155:"))
    else { throw WalletFailure("Choose a funding wallet for this pair.") }
    let result: FlashOrderReview = try await post(
      "prepare", PrepareRequest(request: request, funder: account.address, takeProfit: takeProfit))
    let plan = result.signPlan
    let intent = WalletTransferIntent(
      chain: request.input.chain, from: account.address, to: account.address, amount: request.amount)
    let addresses = [(plan.funder, account.address),
      (plan.fromToken, request.input.address), (plan.toToken, request.output.address)]
    guard request.input.chain == plan.chain,
      addresses.allSatisfy({ actual, expected in
        account.family == .solana ? actual == expected : actual.caseInsensitiveCompare(expected) == .orderedSame
      }),
      (0...255).contains(result.spendDecimals),
      intent.atomicUnits(decimals: result.spendDecimals) == plan.fromAmount,
      result.orderType == (takeProfit ? "take-profit" : request.orderType.rawValue),
      plan.expiry > .now, plan.orderExpiry > plan.expiry
    else { throw WalletFailure("The Flash review does not match your order.") }
    if let approval = result.approval {
      guard account.family == .evm,
        approval.spender.caseInsensitiveCompare(FlashAllowanceReview.settlement) == .orderedSame,
        approval.plan.planId == plan.planId, approval.plan.chainId == plan.chainId,
        approval.plan.funder.caseInsensitiveCompare(plan.funder) == .orderedSame,
        approval.plan.token.caseInsensitiveCompare(plan.fromToken) == .orderedSame,
        approval.plan.amount == plan.fromAmount, approval.plan.expiresAt == plan.expiresAt
      else { throw WalletFailure("The Flash approval does not match your order.") }
    }
    if let setup = result.solanaSetup {
      guard account.family == .solana, result.approval == nil, setup.planId == plan.planId,
        setup.setup.funder == account.address, setup.setup.inputMint == plan.fromToken,
        setup.setup.outputMint == plan.toToken, setup.setup.amount == plan.fromAmount,
        setup.setup.decimals == result.spendDecimals, setup.expiresAt == plan.expiresAt,
        setup.feeLamports > 0, setup.lastValidBlockHeight > 0,
        (setup.newAccounts > 0) == (setup.rentLamports > 0)
      else { throw WalletFailure("The Flash setup does not match your order.") }
    }
    return result
  }

  func approve(plan: FlashAllowancePlan, transaction: WalletSignedTransfer) async throws {
    let receipt: ApprovalReceipt = try await post(
      "approve", ApprovalSubmission(planId: plan.planId, signed: transaction.signed, transactionId: transaction.transactionId))
    guard receipt.transactionId == transaction.transactionId else {
      throw WalletFailure("Check Activity to confirm the Flash approval.")
    }
  }

  func setupSolana(plan: FlashSolanaSetupPlan, transaction: WalletSignedTransfer) async throws {
    let receipt: ApprovalReceipt = try await post(
      "setup-solana", ApprovalSubmission(planId: plan.planId, signed: transaction.signed, transactionId: transaction.transactionId))
    guard receipt.transactionId == transaction.transactionId else {
      throw WalletFailure("Check Activity to confirm the Flash setup.")
    }
  }

  func submit(plan: FlashOrderSignPlan, signature: WalletSignedTransfer) async throws -> FlashOrderAcknowledgement {
    guard signature.transactionId == plan.planId else { throw WalletFailure("Refresh the Flash order review.") }
    return try await post("submit", SubmitRequest(planId: plan.planId, signature: signature.signed))
  }

  private func post<Payload: Encodable, Output: Decodable>(_ path: String, _ payload: Payload) async throws -> Output {
    let body = try JSONEncoder().encode(payload)
    let data = try await LocalBackendClient.post("api/flash/orders/\(path)", body: body)
    return try JSONDecoder().decode(Output.self, from: data)
  }
}
