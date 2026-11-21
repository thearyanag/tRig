import Foundation
import Testing

@testable import TradingWorkspace

private func marketAsset(_ chain: String) -> Asset {
  Asset(
    id: "0x1111111111111111111111111111111111111111", name: "Token", symbol: "TOK",
    network: chain, pool: "0x2222222222222222222222222222222222222222", decimals: 18,
    priceUsd: nil, chainId: chain, marketNetwork: chain == "eip155:1" ? "eth" : "base")
}
private func snapshot(_ asset: Asset) -> MarketSnapshot {
  MarketSnapshot(
    chain: asset.chainID, address: asset.id, pool: asset.pool, asset: asset,
    high24h: 2, low24h: 1, rangeStart: 100, rangeEnd: 200, links: [], fetchedAt: 200, warning: nil)
}
private func trades(_ asset: Asset) -> RecentTrades {
  RecentTrades(
    chain: asset.chainID, address: asset.id, pool: asset.pool, rows: [], fetchedAt: 200,
    warning: nil)
}

@Test @MainActor func lateMarketDataCannotLeakAcrossChainsWithTheSameAddress() async {
  var snapshots: [String: CheckedContinuation<MarketSnapshot, any Error>] = [:]
  var feeds: [String: CheckedContinuation<RecentTrades, any Error>] = [:]
  let store = MarketDataStore(
    fetchSnapshot: { asset in
      try await withCheckedThrowingContinuation { snapshots[asset.chainID] = $0 }
    },
    fetchTrades: { asset in
      try await withCheckedThrowingContinuation { feeds[asset.chainID] = $0 }
    })
  let base = marketAsset("eip155:8453")
  let eth = marketAsset("eip155:1")
  let first = Task { await store.refresh(base) }
  while snapshots.count < 1 || feeds.count < 1 { await Task.yield() }
  let second = Task { await store.refresh(eth) }
  while snapshots.count < 2 || feeds.count < 2 { await Task.yield() }
  snapshots[eth.chainID]?.resume(returning: snapshot(eth))
  feeds[eth.chainID]?.resume(returning: trades(eth))
  await second.value
  snapshots[base.chainID]?.resume(returning: snapshot(base))
  feeds[base.chainID]?.resume(returning: trades(base))
  await first.value
  #expect(store.snapshot?.chain == eth.chainID && store.trades?.chain == eth.chainID)
  #expect(store.snapshot?.matches(base) == false)
}

@Test @MainActor func mismatchedMarketResponsesRemainErrors() async {
  let base = marketAsset("eip155:8453")
  let eth = marketAsset("eip155:1")
  let store = MarketDataStore(
    fetchSnapshot: { _ in snapshot(eth) }, fetchTrades: { _ in trades(eth) })
  await store.refresh(base)
  #expect(store.snapshot == nil && store.trades == nil)
  #expect(store.snapshotError != nil && store.tradesError != nil)
}
