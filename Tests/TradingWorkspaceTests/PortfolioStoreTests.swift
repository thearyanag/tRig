import Foundation
import Testing

@testable import TradingWorkspace

@MainActor private final class DeferredPortfolioBackend: PortfolioBackend {
  var reads: [(PortfolioPeriod, CheckedContinuation<PortfolioCache, any Error>)] = []
  var claims = 0
  func cached(period: PortfolioPeriod) async throws -> PortfolioCache {
    try await withCheckedThrowingContinuation { reads.append((period, $0)) }
  }
  func reconcile(accounts: [PortfolioAccount], removed: [ConnectionService], revision: Int64?)
    async throws
  {}
  func claim(period: PortfolioPeriod, available: [PortfolioAccount], force: Bool) async throws
    -> PortfolioSyncPlan
  {
    claims += 1
    return PortfolioSyncPlan(revision: 1, jobs: [])
  }
  func complete(plan: PortfolioSyncPlan, results: [PortfolioSyncResult]) async throws {}
}
private func cachedPortfolio(_ value: String, period: PortfolioPeriod = .day) throws
  -> PortfolioCache
{
  let snapshot: [String: Any] = [
    "scope": "all", "period": period.rawValue, "totalValueUsd": value, "holdings": [],
    "history": [], "sourceCount": 1, "warnings": [], "partial": false, "asOf": 123,
  ]
  return try JSONDecoder().decode(
    PortfolioCache.self,
    from: JSONSerialization.data(withJSONObject: [
      "revision": 1,
      "accounts": [
        ["source": "pump", "accountWallet": "So11111111111111111111111111111111111111112"]
      ],
      "views": ["all": snapshot, "pump": snapshot, "fomo": snapshot], "market": snapshot,
      "cached": true,
    ]))
}
@Test @MainActor func savedPortfolioLoadsBeforeConnectionsAreConfirmed() async throws {
  let backend = DeferredPortfolioBackend()
  let shared = PortfolioStore(backend: backend)
  let task = Task { await shared.loadCached() }
  while backend.reads.isEmpty { await Task.yield() }
  backend.reads[0].1.resume(returning: try cachedPortfolio("12"))
  await task.value
  #expect(shared.views?.all.totalValueUsd == "12")
  #expect(shared.market?.totalValueUsd == "12")
  #expect(shared.isSaved)
  #expect(shared.isRestoringConnections)
  #expect(backend.claims == 0)
}
@Test @MainActor func olderLocalResponsesCannotOverwriteNewerSharedState() async throws {
  let backend = DeferredPortfolioBackend()
  let shared = PortfolioStore(backend: backend)
  let old = Task { await shared.loadCached() }
  while backend.reads.count < 1 { await Task.yield() }
  let new = Task { await shared.loadCached() }
  while backend.reads.count < 2 { await Task.yield() }
  backend.reads[1].1.resume(returning: try cachedPortfolio("20"))
  await new.value
  backend.reads[0].1.resume(returning: try cachedPortfolio("10"))
  await old.value
  #expect(shared.market?.totalValueUsd == "20")
}
@Test @MainActor func cachedReadFailureKeepsThePreviousSuccessfulSnapshot() async throws {
  let backend = DeferredPortfolioBackend()
  let shared = PortfolioStore(backend: backend)
  let first = Task { await shared.loadCached() }
  while backend.reads.count < 1 { await Task.yield() }
  backend.reads[0].1.resume(returning: try cachedPortfolio("12"))
  await first.value
  let second = Task { await shared.loadCached() }
  while backend.reads.count < 2 { await Task.yield() }
  backend.reads[1].1.resume(throwing: PortfolioReadFailure(message: "unavailable"))
  await second.value
  #expect(shared.market?.totalValueUsd == "12")
  #expect(shared.error != nil)
}
@Test @MainActor func oldPeriodResponseDoesNotReplaceTheNewSelection() async throws {
  let backend = DeferredPortfolioBackend()
  let store = PortfolioStore(backend: backend)
  let old = Task { await store.loadCached() }
  while backend.reads.count < 1 { await Task.yield() }
  store.selectPeriod(.month)
  let new = Task { await store.loadCached() }
  while backend.reads.count < 2 { await Task.yield() }
  backend.reads[1].1.resume(returning: try cachedPortfolio("20", period: .month))
  await new.value
  backend.reads[0].1.resume(returning: try cachedPortfolio("10"))
  await old.value
  #expect(store.views?.all.period == .month)
  #expect(store.market?.totalValueUsd == "20")
}
