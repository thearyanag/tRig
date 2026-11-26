import Foundation

enum WalletDerivation {
  struct Response: Decodable, Sendable {
    let accounts: [WalletAccount]?
    let recoveryPhrase: String?
    let error: String?
    let transaction: WalletSignedTransfer?
  }

  private struct Request: Encodable, Sendable {
    let operation: String
    var secret: String?
    var family: WalletFamily?
    var passphrase: String?
    var accountIndex: UInt32?
    var transfer: WalletTransferPlan?
  }

  private struct TradeRequest<Plan: Encodable & Sendable>: Encodable, Sendable {
    let operation: WalletTradeOperation
    let secret: String
    let family: WalletFamily?
    let passphrase: String?
    let accountIndex: UInt32?
    let trade: Plan
  }

  static func generate() async throws -> (WalletSecret, [WalletAccount]) {
    let result = try await run(Request(operation: "generate"))
    guard let phrase = result.recoveryPhrase, let accounts = result.accounts, accounts.count == 2 else {
      throw WalletFailure("The local wallet helper couldn’t create a wallet.")
    }
    return (WalletSecret(kind: .phrase, value: phrase), accounts)
  }

  static func inspect(_ secret: WalletSecret) async throws -> [WalletAccount] {
    let response = try await run(Request(
      operation: secret.kind == .phrase ? "inspectPhrase" : "inspectKey",
      secret: secret.value, family: secret.family, passphrase: secret.passphrase,
      accountIndex: secret.accountIndex))
    guard let accounts = response.accounts, accounts.count == (secret.kind == .phrase ? 2 : 1) else {
      throw WalletFailure("The local wallet helper couldn’t derive the account.")
    }
    return accounts
  }

  static func sign(_ plan: WalletTransferPlan, with secret: WalletSecret) async throws -> WalletSignedTransfer {
    let response = try await run(Request(
      operation: "signTransfer", secret: secret.value, family: secret.family,
      passphrase: secret.passphrase, accountIndex: secret.accountIndex, transfer: plan))
    guard let transaction = response.transaction else { throw WalletFailure("The transfer couldn’t be signed.") }
    return transaction
  }

  static func signTrade<Plan: Encodable & Sendable>(
    _ operation: WalletTradeOperation, plan: Plan, with secret: WalletSecret
  ) async throws -> WalletSignedTransfer {
    let response = try await run(TradeRequest(
      operation: operation, secret: secret.value, family: secret.family,
      passphrase: secret.passphrase, accountIndex: secret.accountIndex, trade: plan))
    guard let transaction = response.transaction else { throw WalletFailure("The trade couldn’t be signed.") }
    return transaction
  }

  private static func run(_ request: some Encodable & Sendable) async throws -> Response {
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/trig-wallet-signer")
    let response = try await Task.detached(priority: .userInitiated) {
      guard FileManager.default.isExecutableFile(atPath: helper.path) else {
        throw WalletFailure("The local wallet helper is missing. Reinstall tRig.")
      }
      var payload = try JSONEncoder().encode(request)
      defer { payload.resetBytes(in: 0..<payload.count) }
      guard payload.count <= 16_384 else { throw WalletFailure("Wallet input is too large.") }

      let process = Process()
      let input = Pipe()
      let output = Pipe()
      process.executableURL = helper
      process.environment = [:]
      process.standardInput = input
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try process.run()

      do {
        try input.fileHandleForWriting.write(contentsOf: payload)
        try input.fileHandleForWriting.close()
      } catch {
        if process.isRunning { process.terminate() }
        throw WalletFailure("Couldn’t contact the local wallet helper.")
      }

      var bytes = output.fileHandleForReading.readDataToEndOfFile()
      defer { bytes.resetBytes(in: 0..<bytes.count) }
      process.waitUntilExit()
      guard process.terminationStatus == 0, bytes.count <= 16_384 else {
        throw WalletFailure("The local wallet helper did not complete the request.")
      }
      return try JSONDecoder().decode(Response.self, from: bytes)
    }.value
    try Task.checkCancellation()
    if let failure = response.error { throw WalletFailure(failure) }
    return response
  }
}
