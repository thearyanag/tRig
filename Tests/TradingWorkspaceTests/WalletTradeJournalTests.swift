import Foundation
import Testing

@testable import TradingWorkspace

@MainActor
@Test func walletTradeJournalKeepsAmbiguousSubmissionsAcrossRelaunch() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let vault = WalletVault(url: directory.appending(path: "vault.json"), service: "trig-test")
  let trade = WalletTradeDetails(
    provider: .jupiter, title: "Swap SOL for USDC", chain: "solana", requestID: "test-order")
  let wallet = UUID()
  let entry = WalletTradeActivity(
    details: trade, walletID: wallet, address: "test-address", transactionID: "test-signature",
    createdAt: .now, status: .pending)
  try WalletTradeJournal(vault: vault).record(entry)

  let restored = WalletTradeJournal(vault: vault)
  #expect(restored.entries.first?.status == .pending)
  #expect(restored.entries.first?.walletID == wallet)
  #expect(throws: WalletFailure.self) { try restored.checkNew(trade) }
  try restored.update(entry.id, to: .confirmed)
  try restored.update(entry.id, to: .failed)
  #expect(WalletTradeJournal(vault: vault).entries.first?.status == .confirmed)
}
