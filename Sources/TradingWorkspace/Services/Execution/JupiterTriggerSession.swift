import Foundation

struct JupiterTriggerSessionStatus: Decodable, Sendable {
  let authenticated: Bool
}

@MainActor
enum JupiterTriggerAPI {
  static func get<Response: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Response {
    let data = try await LocalBackendClient.get("api/jupiter/trigger/\(path)", query: query)
    return try JSONDecoder().decode(Response.self, from: data)
  }

  static func post<Response: Decodable>(_ path: String, _ request: some Encodable) async throws -> Response {
    let body = try JSONEncoder().encode(request)
    let data = try await LocalBackendClient.post("api/jupiter/trigger/\(path)", body: body)
    return try JSONDecoder().decode(Response.self, from: data)
  }
}

@MainActor
struct JupiterTriggerSession {
  private static var signIns: [String: Task<JupiterTriggerSessionStatus, Error>] = [:]

  private struct Request: Encodable {
    let wallet: String
  }

  private struct Challenge: Codable, Sendable {
    let wallet: String
    let challenge: String
    let expiresAt: UInt64

    var expiry: Date { Date(timeIntervalSince1970: Double(expiresAt)) }
  }

  private struct Verification: Encodable {
    let wallet: String
    let signature: String
  }

  private func status(account: WalletAccount) async throws -> JupiterTriggerSessionStatus {
    guard account.family == .solana else { throw WalletFailure("Choose a Solana wallet for Jupiter.") }
    return try await JupiterTriggerAPI.get("session", query: [
      URLQueryItem(name: "wallet", value: account.address)
    ])
  }

  @discardableResult
  func authenticate(
    walletStore: WalletStore, wallet: TradingWallet, account: WalletAccount, unlockIfNeeded: Bool = true
  ) async throws -> JupiterTriggerSessionStatus {
    guard wallet.accounts.contains(account) else { throw WalletFailure("The selected wallet is unavailable.") }
    let current = try await status(account: account)
    try Task.checkCancellation()
    if current.authenticated { return current }
    if let signIn = Self.signIns[account.id] {
      return try await signIn.value
    }
    if !unlockIfNeeded && (!walletStore.isUnlocked || walletStore.submitting) { return current }

    // Both the ticket and the Orders tab can request sign-in for the same wallet.
    // Jupiter accepts a single outstanding challenge per wallet.
    let signIn = Task {
      if unlockIfNeeded { try await walletStore.unlock() }
      guard walletStore.isUnlocked else { return current }
      return try await signInWithUnlockedWallet(walletStore: walletStore, wallet: wallet, account: account)
    }
    Self.signIns[account.id] = signIn
    defer { Self.signIns[account.id] = nil }
    return try await signIn.value
  }

  private func signInWithUnlockedWallet(
    walletStore: WalletStore, wallet: TradingWallet, account: WalletAccount
  ) async throws -> JupiterTriggerSessionStatus {
    let unlockSession = walletStore.lockID
    let challenge: Challenge = try await JupiterTriggerAPI.post("auth/challenge", Request(wallet: account.address))
    guard walletStore.lockID == unlockSession else { throw CancellationError() }
    guard challenge.wallet == account.address, challenge.expiry > .now else {
      throw WalletFailure("Jupiter returned an expired challenge or a challenge for a different wallet.")
    }
    let connected = try await walletStore.authorizeTrade(
      operation: .jupiterTriggerAuth, plan: challenge, wallet: wallet, account: account,
      expiresAt: challenge.expiry
    ) { signed -> JupiterTriggerSessionStatus in
      try await JupiterTriggerAPI.post(
        "auth/verify", Verification(wallet: account.address, signature: signed.signed))
    }
    guard connected.authenticated else { throw WalletFailure("Jupiter could not sign in this wallet.") }
    return connected
  }
}
