import Foundation

struct JupiterSwapPlan: Decodable, Sendable {
  struct Terms: Codable, Sendable {
    let wallet: String
    let inputMint: String
    let outputMint: String
    let inAmount: String
    let minimumOut: String
    let slippageBps: Int
    let maxNetworkCost: String
    let expiresAt: Double
  }

  struct SigningPayload: Encodable, Sendable {
    let transaction: String
    let terms: Terms
  }

  let terms: Terms
  let transaction: String
  let requestId: String
  let lastValidBlockHeight: UInt64
  let outAmount: String
  let feeBps: Int
  let inputBalance: String
  let feeBalance: String
  let wrappedSolReturned: String
  let inputDecimals: Int
  let outputDecimals: Int

  var expiry: Date { Date(timeIntervalSince1970: terms.expiresAt) }
  var signingPayload: SigningPayload { SigningPayload(transaction: transaction, terms: terms) }

  func matches(quote: SwapQuote, account: WalletAccount) -> Bool {
    guard terms.wallet == account.address, account.family == .solana,
      terms.inputMint == quote.inputMint, terms.outputMint == quote.outputMint,
      terms.inAmount == quote.inAmount, terms.slippageBps == quote.slippageBps,
      inputDecimals == quote.inputDecimals, outputDecimals == quote.outputDecimals,
      let amount = UInt64(terms.inAmount), amount > 0,
      let balance = UInt64(inputBalance), let feeBalance = UInt64(feeBalance),
      UInt64(wrappedSolReturned) != nil,
      let minimum = UInt64(terms.minimumOut), minimum > 0,
      let estimated = UInt64(outAmount), estimated >= minimum,
      let cost = UInt64(terms.maxNetworkCost), (1...50_000_000).contains(cost),
      (0...100).contains(feeBps), !requestId.isEmpty, lastValidBlockHeight > 0,
      expiry > .now, expiry.timeIntervalSinceNow <= 60, !transaction.isEmpty
    else { return false }
    return balance >= amount && feeBalance >= cost
      && (terms.inputMint != "So11111111111111111111111111111111111111112" || balance - amount >= cost)
  }

  static func units(_ value: String, decimals: Int) -> String {
    guard let amount = UInt64(value), (0...255).contains(decimals) else { return "—" }
    guard decimals > 0 else { return String(amount) }
    let digits = String(amount)
    let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
    let fraction = padded.suffix(decimals).reversed().drop(while: { $0 == "0" }).reversed()
    let whole = padded.dropLast(decimals)
    return fraction.isEmpty ? String(whole) : "\(whole).\(String(fraction))"
  }
}

@MainActor
struct JupiterSwapClient {
  private struct Prepare: Encodable {
    let wallet: String
    let inputMint: String
    let outputMint: String
    let inAmount: String
    let slippageBps: Int
  }

  private struct Submit: Encodable {
    let requestId: String
    let signed: String
    let transactionId: String
  }

  private struct Receipt: Decodable {
    let status: WalletTradeStatus
  }

  func prepare(quote: SwapQuote, account: WalletAccount) async throws -> JupiterSwapPlan {
    let input = Prepare(
      wallet: account.address, inputMint: quote.inputMint, outputMint: quote.outputMint,
      inAmount: quote.inAmount, slippageBps: quote.slippageBps)
    let data = try await LocalBackendClient.post(
      "api/swap/jupiter/prepare", body: JSONEncoder().encode(input))
    let plan = try JSONDecoder().decode(JupiterSwapPlan.self, from: data)
    guard plan.matches(quote: quote, account: account) else {
      throw WalletFailure("The swap terms or funding balance don’t match. Refresh the review.")
    }
    return plan
  }

  func submit(_ signed: WalletSignedTransfer, for plan: JupiterSwapPlan) async throws -> WalletTradeStatus {
    let input = Submit(requestId: plan.requestId, signed: signed.signed, transactionId: signed.transactionId)
    let data = try await LocalBackendClient.post(
      "api/swap/jupiter/submit", body: JSONEncoder().encode(input))
    return try JSONDecoder().decode(Receipt.self, from: data).status
  }
}
