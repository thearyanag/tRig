import Foundation
import Observation

@MainActor @Observable final class MarketDataStore {
  private(set) var snapshot: MarketSnapshot?
  private(set) var trades: RecentTrades?
  private(set) var snapshotError: String?
  private(set) var tradesError: String?
  private(set) var loadingStats = false
  private(set) var loadingTrades = false
  @ObservationIgnored private var identity = ""
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var rangeTask: Task<Void, Never>?
  @ObservationIgnored private let fetchSnapshot: @MainActor (Asset) async throws -> MarketSnapshot
  @ObservationIgnored private let fetchTrades: @MainActor (Asset) async throws -> RecentTrades

  init(
    fetchSnapshot: @escaping @MainActor (Asset) async throws -> MarketSnapshot = {
      try await MarketDataClient().snapshot($0)
    },
    fetchTrades: @escaping @MainActor (Asset) async throws -> RecentTrades = {
      try await MarketDataClient().trades($0)
    }
  ) {
    self.fetchSnapshot = fetchSnapshot
    self.fetchTrades = fetchTrades
  }

  func select(_ asset: Asset) {
    guard identity != asset.marketKey else { return }
    generation = UUID()
    rangeTask?.cancel()
    rangeTask = nil
    identity = asset.marketKey
    snapshot = nil
    trades = nil
    snapshotError = nil
    tradesError = nil
    loadingStats = false
    loadingTrades = false
  }
  func refresh(_ asset: Asset) async {
    select(asset)
    guard asset.hasChart else { return }
    async let stats: Void = loadStats(asset)
    async let feed: Void = loadTrades(asset)
    _ = await (stats, feed)
  }
  private func loadStats(_ asset: Asset) async {
    guard !loadingStats else { return }
    let id = generation
    loadingStats = true
    defer { if generation == id { loadingStats = false } }
    do {
      let result = try await fetchSnapshot(asset)
      guard !Task.isCancelled, generation == id else { return }
      guard result.matches(asset) else {
        throw LocalBackendClient.RequestError(message: "Market identity could not be confirmed.")
      }
      snapshot = result
      snapshotError = result.warning
      if result.rangeLoading == true { pollRange(asset, generation: id) }
    } catch {
      if !Task.isCancelled, generation == id { snapshotError = error.localizedDescription }
    }
  }
  private func pollRange(_ asset: Asset, generation id: UUID) {
    rangeTask?.cancel()
    rangeTask = Task { [weak self] in
      for _ in 0..<12 {
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        guard let self, self.generation == id, !Task.isCancelled else { return }
        do {
          let result = try await self.fetchSnapshot(asset)
          guard !Task.isCancelled, self.generation == id, result.matches(asset) else { return }
          self.snapshot = result
          self.snapshotError = result.warning
          if result.rangeLoading != true { return }
        } catch { return }
      }
    }
  }
  private func loadTrades(_ asset: Asset) async {
    guard !loadingTrades else { return }
    let id = generation
    loadingTrades = true
    defer { if generation == id { loadingTrades = false } }
    do {
      let result = try await fetchTrades(asset)
      guard !Task.isCancelled, generation == id else { return }
      guard result.matches(asset) else {
        throw LocalBackendClient.RequestError(message: "Trade identity could not be confirmed.")
      }
      trades = result
      tradesError = result.warning
    } catch {
      if !Task.isCancelled, generation == id { tradesError = error.localizedDescription }
    }
  }
}

@MainActor @Observable final class MarketNetworkStore {
  private(set) var networks: [MarketNetwork] = []
  private(set) var error: String?
  func load() async {
    do {
      let data = try await LocalBackendClient.get("api/markets/networks", query: [])
      networks = try JSONDecoder().decode([MarketNetwork].self, from: data)
      error = nil
    } catch { self.error = "Network coverage could not refresh." }
  }
}
