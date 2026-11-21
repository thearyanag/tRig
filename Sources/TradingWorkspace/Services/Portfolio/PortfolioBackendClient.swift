import Foundation

struct PortfolioAccount: Codable, Equatable, Sendable {
  let source: ConnectionService
  let accountWallet: String
}
struct PortfolioCache: Decodable, Sendable {
  let revision: Int64
  let accounts: [PortfolioAccount]
  let views: PortfolioViews
  let market: PortfolioSnapshot
  let cached: Bool
}
struct PortfolioSyncJob: Codable, Sendable {
  let source: ConnectionService
  let accountWallet: String
  let period: PortfolioPeriod
  let token: Int64
}
struct PortfolioSyncPlan: Decodable, Sendable {
  let revision: Int64
  let jobs: [PortfolioSyncJob]
}
struct PortfolioSyncResult: Sendable {
  let job: PortfolioSyncJob
  let payload: PortfolioProviderPayload?
  let error: String?
}

@MainActor protocol PortfolioBackend {
  func cached(period: PortfolioPeriod) async throws -> PortfolioCache
  func reconcile(accounts: [PortfolioAccount], removed: [ConnectionService], revision: Int64?)
    async throws
  func claim(period: PortfolioPeriod, available: [PortfolioAccount], force: Bool) async throws
    -> PortfolioSyncPlan
  func complete(plan: PortfolioSyncPlan, results: [PortfolioSyncResult]) async throws
}
@MainActor struct PortfolioBackendClient: PortfolioBackend {
  func cached(period: PortfolioPeriod) async throws -> PortfolioCache {
    let data = try await LocalBackendClient.get(
      "api/portfolio/cache", query: [URLQueryItem(name: "period", value: period.rawValue)])
    return try JSONDecoder().decode(PortfolioCache.self, from: data)
  }
  func reconcile(accounts: [PortfolioAccount], removed: [ConnectionService], revision: Int64?)
    async throws
  {
    struct Request: Encodable {
      let accounts: [PortfolioAccount]
      let removed: [ConnectionService]
      let expectedRevision: Int64?
    }
    _ = try await LocalBackendClient.post(
      "api/portfolio/accounts",
      body: JSONEncoder().encode(
        Request(accounts: accounts, removed: removed, expectedRevision: revision)))
  }
  func claim(period: PortfolioPeriod, available: [PortfolioAccount], force: Bool) async throws
    -> PortfolioSyncPlan
  {
    struct Request: Encodable {
      let period: PortfolioPeriod
      let available: [PortfolioAccount]
      let force: Bool
    }
    let data = try await LocalBackendClient.post(
      "api/portfolio/sync",
      body: JSONEncoder().encode(Request(period: period, available: available, force: force)))
    return try JSONDecoder().decode(PortfolioSyncPlan.self, from: data)
  }
  func complete(plan: PortfolioSyncPlan, results: [PortfolioSyncResult]) async throws {
    let rows = try results.map { result -> [String: Any] in
      var row: [String: Any] = [
        "job": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.job))
      ]
      if let payload = result.payload { row["provider"] = try payload.requestObject() }
      if let error = result.error { row["error"] = error }
      return row
    }
    _ = try await LocalBackendClient.post(
      "api/portfolio/sync/complete",
      body: JSONSerialization.data(withJSONObject: ["revision": plan.revision, "results": rows]))
  }
}
