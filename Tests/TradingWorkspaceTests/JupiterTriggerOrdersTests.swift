import Foundation
import Testing
@testable import TradingWorkspace

private func withdrawalOrder() throws -> JupiterTriggerOrder {
  let json = """
    {
      "id":"4bef6e1a-04cb-49ff-8f00-a6974ae266be",
      "orderType":"oco",
      "orderState":"pending_withdraw",
      "rawState":"ready_to_cancel",
      "inputMint":"So11111111111111111111111111111111111111112",
      "outputMint":"EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
      "initialInputAmount":"1500000000",
      "remainingInputAmount":"1000000000",
      "tpPriceUsd":"180.25",
      "slPriceUsd":"110.0",
      "canCancel":true
    }
    """
  return try JSONDecoder().decode(JupiterTriggerOrder.self, from: Data(json.utf8))
}

@Test func jupiterTriggerHistoryIdentifiesOrdersWaitingForWithdrawal() throws {
  let order = try withdrawalOrder()

  #expect(order.needsWithdrawal)
  #expect(order.canCancel)
  #expect(order.status == "Withdrawal required")
  #expect(order.amount == "1.5 SOL")
  #expect(order.price == "TP $180.25 · SL $110.00")
}

@Test func jupiterTriggerOnlyBlocksPendingWithdrawalsForTheSameOrderAndWallet() throws {
  let order = try withdrawalOrder()
  let account = WalletAccount(family: .solana, address: "wallet")
  let anotherAccount = WalletAccount(family: .solana, address: "another-wallet")
  var activity = WalletTradeActivity(
    details: WalletTradeDetails(
      provider: .jupiterTrigger, title: "Withdraw from Jupiter", chain: "solana",
      requestID: "withdraw:\(order.id):old-plan"),
    walletID: UUID(), address: account.address, transactionID: "fixture-signature",
    createdAt: .now, status: .pending)

  #expect(JupiterTriggerWithdrawal.pending(order: order, account: account, entries: [activity]))
  #expect(!JupiterTriggerWithdrawal.pending(order: order, account: anotherAccount, entries: [activity]))

  activity.status = .failed
  #expect(!JupiterTriggerWithdrawal.pending(order: order, account: account, entries: [activity]))
}
