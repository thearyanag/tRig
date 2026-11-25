import Foundation
import Observation
import PortfolioPulseSupport

/// Shared app state backed by the Rust repository. There is no provider payload cache in Swift.
@MainActor @Observable
final class PortfolioStore {
  private(set) var cache: PortfolioCache?
  private(set) var isRefreshing = false
  private(set) var error: String?
  private(set) var isRestoringConnections = true
  private(set) var period = PortfolioPeriod.day
  var isActive = true
  var views: PortfolioViews? { cache?.views }
  var market: PortfolioSnapshot? { cache?.market }
  var connectedCount: Int { cache?.accounts.count ?? 0 }
  var marketIsSaved: Bool {
    guard let timestamp = market?.asOf else { return true }
    return Date().timeIntervalSince1970 - timestamp >= 60 || error != nil || connectionNotice != nil
  }
  var isSaved: Bool { cache?.cached == true || error != nil || connectionNotice != nil }
  var connectionNotice: String? {
    guard let connections, let cache, !cache.accounts.isEmpty else { return nil }
    let unconfirmed = cache.accounts.contains {
      connections.session(for: $0.source).profile?.wallet != $0.accountWallet
    }
    guard unconfirmed else { return nil }
    return isRestoringConnections
      ? "Showing saved data while account connections are checked."
      : "Showing saved data for accounts that could not be confirmed. Check their connections in Settings."
  }
  @ObservationIgnored private let backend: any PortfolioBackend
  @ObservationIgnored private let reader:
    @MainActor (ConnectionService, ConnectionStore, PortfolioPeriod) async throws ->
      PortfolioProviderPayload
  @ObservationIgnored private weak var connections: ConnectionStore?
  @ObservationIgnored private var startup: Task<Void, Never>?
  @ObservationIgnored private var polling: Task<Void, Never>?
  @ObservationIgnored private var worker: Task<Void, Never>?
  @ObservationIgnored private var pending = false
  @ObservationIgnored private var forcePending = false
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var cacheReadID = UUID()
  @ObservationIgnored private var lastIdentityCheck = Date()
  @ObservationIgnored private var serverRevision: Int64?
  @ObservationIgnored private let pulsePublisher = PortfolioPulseStorage.shared().map {
    PortfolioPulsePublisher(storage: $0)
  }
  @ObservationIgnored private var lastPulseRefresh = Date.distantPast

  init(
    backend: any PortfolioBackend = PortfolioBackendClient(),
    reader:
      @escaping @MainActor (ConnectionService, ConnectionStore, PortfolioPeriod) async throws ->
      PortfolioProviderPayload = { source, connections, period in
        try await PortfolioReadClient().read(
          source: source, connections: connections, period: period)
      }
  ) {
    self.backend = backend
    self.reader = reader
  }

  func bind(_ connections: ConnectionStore) {
    self.connections = connections
    connections.onDisconnect = { [weak self] source in
      guard let self else { return }
      self.generation = UUID()
      self.cache = nil
      self.pulsePublisher?.publish(nil)
      try await self.backend.reconcile(accounts: [], removed: [source], revision: nil)
      await self.loadCached()
      self.requestUpdate()
    }
  }
  func start(_ connections: ConnectionStore) {
    guard startup == nil else { return }
    bind(connections)
    startup = Task { [weak self] in
      await self?.loadCached()
      await connections.restore()
      guard let self else { return }
      self.isRestoringConnections = false
      self.lastIdentityCheck = .now
      self.requestUpdate()
    }
    polling = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(5)) } catch { break }
        guard let self else { break }
        if self.isActive { self.requestUpdate() }
      }
    }
  }
  func selectPeriod(_ value: PortfolioPeriod) {
    guard period != value else { return }
    period = value
    requestUpdate()
  }
  func connectionChanged() {
    generation = UUID()
    // Never render a previous wallet after a different account is confirmed.
    if let cache, let connections,
      cache.accounts.contains(where: { account in
        if let wallet = connections.session(for: account.source).profile?.wallet {
          return wallet != account.accountWallet
        }
        return false
      })
    {
      self.cache = nil
      pulsePublisher?.publish(nil)
    }
    requestUpdate()
  }
  func refresh() { requestUpdate(force: true) }
  func requestUpdate(force: Bool = false) {
    pending = true
    forcePending = forcePending || force
    guard worker == nil else { return }
    worker = Task { [weak self] in
      guard let self else { return }
      while self.pending && !Task.isCancelled {
        self.pending = false
        let force = self.forcePending
        self.forcePending = false
        await self.update(force: force)
      }
      self.worker = nil
    }
  }
  func loadCached() async {
    let requested = period
    let id = generation
    let readID = UUID()
    cacheReadID = readID
    do {
      let result = try await backend.cached(period: requested)
      guard !Task.isCancelled, generation == id, period == requested, cacheReadID == readID else {
        return
      }
      serverRevision = result.revision
      if let connections,
        result.accounts.contains(where: { account in
          if let current = connections.session(for: account.source).profile?.wallet {
            return current != account.accountWallet
          }
          return false
        })
      {
        return
      }
      cache = result
      error = nil
      if requested == .day { publishPulse(result) }
    } catch {
      guard generation == id, cacheReadID == readID, period == requested else { return }
      self.error = "Saved portfolio data could not be loaded. Try refreshing again."
    }
  }
  private func availableAccounts() -> [PortfolioAccount] {
    guard let connections else { return [] }
    return ConnectionService.allCases.compactMap { source in
      connections.session(for: source).profile.map {
        PortfolioAccount(source: source, accountWallet: $0.wallet)
      }
    }
  }
  private func update(force: Bool) async {
    guard let connections else { return }
    let id = generation
    do {
      await loadCached()
      if !isRestoringConnections && Date().timeIntervalSince(lastIdentityCheck) >= 60 {
        lastIdentityCheck = .now
        for source in ConnectionService.allCases
        where connections.session(for: source).profile == nil {
          await connections.session(for: source).restore()
        }
      }
      guard generation == id, let revision = serverRevision else {
        pending = generation != id
        return
      }
      let available = availableAccounts()
      try await backend.reconcile(accounts: available, removed: [], revision: revision)
      guard generation == id else {
        pending = true
        return
      }
      await loadCached()
      let requested = period
      if try await refreshPeriod(requested, available: available, force: force, connections: connections) {
        error = nil
        await loadCached()
      }
      await refreshPulseIfNeeded(generation: id, available: available, connections: connections)
    } catch {
      guard generation == id else {
        pending = true
        return
      }
      self.error = "Portfolio could not refresh. Your last saved data is still shown."
    }
  }
  private func refreshPeriod(
    _ period: PortfolioPeriod, available: [PortfolioAccount], force: Bool,
    connections: ConnectionStore
  ) async throws -> Bool {
    let plan = try await backend.claim(period: period, available: available, force: force)
    guard !plan.jobs.isEmpty else { return false }
    if period == self.period { isRefreshing = true }
    defer { isRefreshing = false }
    async let pump = read(plan.jobs.first { $0.source == .pump }, connections: connections)
    async let fomo = read(plan.jobs.first { $0.source == .fomo }, connections: connections)
    let results = await [pump, fomo].compactMap { $0 }
    if plan.jobs.contains(where: {
      connections.session(for: $0.source).profile?.wallet != $0.accountWallet
    }) {
      try? await backend.complete(
        plan: plan,
        results: plan.jobs.map {
          PortfolioSyncResult(job: $0, payload: nil, error: "The account changed during refresh.")
        })
      pending = true
      return false
    }
    try await backend.complete(plan: plan, results: results)
    return true
  }

  private func publishPulse(_ cache: PortfolioCache) {
    guard let pulsePublisher else { return }
    guard let connections else { return }
    let available = cache.accounts.filter { account in
      let view = account.source == .pump ? cache.views.pump : cache.views.fomo
      return connections.session(for: account.source).profile?.wallet == account.accountWallet
        && view.sourceCount == 1 && view.totalValueUsd != nil
    }
    guard let first = available.first else {
      if !isRestoringConnections || cache.accounts.isEmpty { pulsePublisher.publish(nil) }
      return
    }
    let scope: PortfolioScope = available.count == 2 ? .all : first.source == .pump ? .pump : .fomo
    pulsePublisher.publish(PortfolioPulseSnapshot(cache: cache, scope: scope))
  }

  private func refreshPulseIfNeeded(
    generation id: UUID, available: [PortfolioAccount], connections: ConnectionStore
  ) async {
    guard pulsePublisher != nil, period != .day, generation == id, !available.isEmpty,
      Date().timeIntervalSince(lastPulseRefresh) >= 300
    else { return }
    lastPulseRefresh = .now
    _ = try? await refreshPeriod(.day, available: available, force: false, connections: connections)
    guard let result = try? await backend.cached(period: .day), generation == id else { return }
    publishPulse(result)
  }

  private func read(_ job: PortfolioSyncJob?, connections: ConnectionStore) async
    -> PortfolioSyncResult?
  {
    guard let job else { return nil }
    guard connections.session(for: job.source).profile?.wallet == job.accountWallet else {
      return PortfolioSyncResult(
        job: job, payload: nil, error: "Confirm this account in Settings before refreshing.")
    }
    do {
      let payload = try await reader(job.source, connections, job.period)
      return PortfolioSyncResult(job: job, payload: payload, error: nil)
    } catch {
      return PortfolioSyncResult(
        job: job, payload: nil,
        error: (error as? PortfolioReadFailure)?.message
          ?? "The portfolio request could not complete. Try refreshing again.")
    }
  }
}
