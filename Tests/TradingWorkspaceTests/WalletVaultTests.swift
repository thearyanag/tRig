import AppKit
import CryptoKit
import Foundation
import Testing
@testable import TradingWorkspace

@Test func walletAddressPickerUsesOneEntryPerAccountFamily() {
  let solana = WalletAccount(family: .solana, address: "TestSolana")
  let evm = WalletAccount(family: .evm, address: "0xTestEvm")
  let duplicate = WalletAccount(family: .evm, address: "0xOtherEvm")
  let wallet = TradingWallet(id: UUID(), label: "Test", accounts: [evm, solana, duplicate], source: .phrase)
  #expect(wallet.addressAccounts == [solana, evm])
  let imported = TradingWallet(id: UUID(), label: "Imported", accounts: [evm], source: .privateKey)
  #expect(imported.addressAccounts == [evm])
}

@Test func walletReceiveQRUsesTheSelectedAccountFamily() {
  let solana = WalletAccount(family: .solana, address: "TestSolana")
  let evm = WalletAccount(family: .evm, address: "0xTestEvm")
  #expect(solana.receiveURI == "solana:TestSolana")
  #expect(evm.receiveURI == "ethereum:0xTestEvm")
}

@MainActor
@Test func backupCopyWritesWordsInOrderAsConcealedText() {
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  let testPhrase = "one two three four five six seven eight nine ten eleven twelve"
  #expect(WalletSetupView.copyBackupPhrase(testPhrase, to: pasteboard))
  #expect(pasteboard.string(forType: .string) == testPhrase)
  #expect(pasteboard.types?.contains(.init("org.nspasteboard.ConcealedType")) == true)
}

@MainActor
@Test func confirmedWalletSaveSurvivesPresentationCancellationAndRelaunch() async throws {
  let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let vault = WalletVault(url: dir.appending(path: "vault.json"), service: "trig-test")
  let key = SymmetricKey(size: .bits256)
  let authorization = AsyncStream<Void>.makeStream()
  let unlock = DispatchSemaphore(value: 0)
  let store = WalletStore(vault: vault, accessKey: { _, _, createIfMissing in
    guard createIfMissing else { throw WalletFailure("Expected first wallet setup.") }
    authorization.continuation.yield()
    authorization.continuation.finish()
    guard unlock.wait(timeout: .now() + 5) == .success else {
      throw WalletFailure("Test authorization timed out.")
    }
    return key
  })
  let account = WalletAccount(family: .solana, address: "SyntheticAddress")
  let secret = WalletSecret(kind: .phrase, value: "Synthetic test phrase")
  let presenter = Task { try await store.add(secret, accounts: [account]) }
  var signals = authorization.stream.makeAsyncIterator()
  _ = await signals.next()
  presenter.cancel()
  unlock.signal()

  let saved = try await presenter.value
  #expect(store.wallets == [saved])
  #expect(WalletStore(vault: vault).wallets == [saved])
  let record = try #require(vault.read().first)
  #expect(try vault.open(record, using: key).value == secret.value)
}

@Test func walletVaultAuthenticatesAccountMetadataAndRejectsOtherKeys() throws {
  let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let vault = WalletVault(url: dir.appending(path: "vault.json"), service: "trig-test")
  let key = SymmetricKey(size: .bits256)
  let wallet = TradingWallet(id: UUID(), label: "Test",
    accounts: [.init(family: .solana, address: "SyntheticAddress")], source: .phrase)
  let secret = WalletSecret(kind: .phrase, value: "Synthetic test input")
  let original = try vault.seal(secret, wallet: wallet, using: key)
  try vault.save([original])
  let bytes = try Data(contentsOf: vault.url)
  #expect(bytes.range(of: Data(secret.value.utf8)) == nil)
  let stored = try #require(vault.read().first)
  #expect(try vault.open(stored, using: key).value == secret.value)
  #expect(throws: CryptoKitError.self) { try vault.open(stored, using: SymmetricKey(size: .bits256)) }
  let tampered = WalletVault.Record(wallet: .init(
    id: wallet.id, label: wallet.label, accounts: [.init(family: .solana, address: "OtherAddress")],
    source: .phrase), encryptedSecret: stored.encryptedSecret)
  #expect(throws: CryptoKitError.self) { try vault.open(tampered, using: key) }
}

@Test func walletTransferAmountKeepsExactChainPrecision() {
  func units(_ amount: String, decimals: Int) -> String? {
    WalletTransferIntent(chain: "solana", from: "sender", to: "recipient", amount: amount)
      .atomicUnits(decimals: decimals)
  }
  #expect(units("0.000000001", decimals: 9) == "1")
  #expect(units("0.0000000001", decimals: 9) == nil)
  #expect(units("00.1200", decimals: 18) == "120000000000000000")
  #expect(units("0", decimals: 9) == nil)
  #expect(units("١", decimals: 9) == nil)
}

@Test func walletTransferActivityKeepsExistingHistoryAndMatchesByToken() throws {
  let data = Data("""
    {"id":"test","intent":{"chain":"eip155:1","from":"0xAbC","to":"0xDef","amount":"1.00"},
    "network":"Ethereum","symbol":"ETH","createdAt":0,"status":"pending"}
    """.utf8)
  let entry = try JSONDecoder().decode(WalletTransferActivity.self, from: data)
  #expect(entry.lastValidBlockHeight == nil)
  #expect(entry.intent.tokenAddress == nil)

  let repeated = WalletTransferIntent(chain: "eip155:1", from: "0xabc", to: "0xdef", amount: "1")
  let token = WalletTransferIntent(
    chain: "eip155:1", from: "0xabc", to: "0xdef", amount: "1", tokenAddress: "0x12")
  #expect(entry.intent.matches(repeated, decimals: 18))
  #expect(!entry.intent.matches(token, decimals: 18))
}
