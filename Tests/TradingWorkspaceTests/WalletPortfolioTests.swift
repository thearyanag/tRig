import Foundation
import Testing

@testable import TradingWorkspace

private let mint = "So11111111111111111111111111111111111111112"
private let owner = "11111111111111111111111111111111"

private func walletRows(address: String, price: String? = "100") -> WalletHoldingsSnapshot {
  WalletHoldingsSnapshot(
    chain: "solana", address: address, tokens: [
      WalletHoldingToken(address: mint, marketMint: mint, name: "Wrapped Solana", symbol: "SOL",
        quantity: "2", decimals: 9, imageUrl: nil, priceUsd: price),
    ], warnings: [], asOf: 101)
}

private func connectedRows(_ lot: PortfolioLot) -> PortfolioSnapshot {
  PortfolioSnapshot(
    scope: "all", period: .day, totalValueUsd: "120", periodPnlUsd: "15", periodPnlPercent: nil,
    unrealizedPnlUsd: "20", unrealizedPnlPercent: "20",
    holdings: [
      PortfolioHolding(
        id: "solana:\(mint)", chain: "solana", mint: mint, marketMint: mint, name: "Wrapped Solana",
        symbol: "SOL", imageUrl: nil, quantity: "1", priceUsd: "120", valueUsd: "120",
        averageEntryUsd: "100", pnlUsd: "20", pnlPercent: "20", sources: [.pump],
        lots: [lot], warnings: []),
    ], history: [.init(time: 100, valueUsd: "120", segment: 0)],
    sourceCount: 1, asOf: 100, warnings: [], historyMessage: nil)
}

private let connectedLot = PortfolioLot(
  id: "connected-fixture", chain: "solana", mint: mint, wallet: owner, name: "Wrapped Solana",
  symbol: "SOL", imageUrl: nil, quantity: "1", priceUsd: "120", valueUsd: "120",
  costBasisUsd: "100", averageEntryUsd: "100", pnlPercent: "20", pnlUsd: "20", sources: [.pump],
  warnings: [], fetchedAt: 100)

@Test func distinctWalletHoldingsIncreaseValueWithoutChangingPortfolioHistoryOrPnl() {
  let result = WalletPortfolio(snapshots: [walletRows(address: mint)], warnings: [])
    .combined(with: connectedRows(connectedLot), scope: "all", period: .day)
  #expect(result.totalValueUsd == "320")
  #expect(result.history.first?.valueUsd == "120")
  #expect(result.periodPnlUsd == "15")
  #expect(result.unrealizedPnlUsd == "20")
  #expect(result.holdings.first?.quantity == "3")
  #expect(result.holdings.first?.pnlUsd == nil)
  #expect(result.holdings.first?.lots.count == 2)
}

@Test func walletAlreadyIncludedInConnectedAccountIsNotCountedTwice() {
  let result = WalletPortfolio(snapshots: [walletRows(address: owner)], warnings: [])
    .combined(with: connectedRows(connectedLot), scope: "all", period: .day)
  #expect(result.totalValueUsd == "120")
  #expect(result.holdings.first?.quantity == "1")
  #expect(result.holdings.first?.pnlUsd == "20")
  #expect(result.holdings.first?.sources == [.pump, .wallet])
}

@Test func unpricedWalletTokenRemainsVisibleWithoutInventingValue() {
  let result = WalletPortfolio(snapshots: [walletRows(address: owner, price: nil)], warnings: [])
    .snapshot(period: .day)
  #expect(result.sourceCount == 1)
  #expect(result.totalValueUsd == nil)
  #expect(result.holdings.first?.quantity == "2")
  #expect(result.warnings.count == 1)
}
