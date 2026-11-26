import SwiftUI

struct PortfolioView: View {
  let store: PortfolioStore
  @Environment(WalletStore.self) private var wallet
  @SceneStorage("portfolio.scope") private var scopeRaw = PortfolioScope.all.rawValue
  @SceneStorage("portfolio.period") private var periodRaw = PortfolioPeriod.day.rawValue
  @State private var showNotices = false
  private var scope: PortfolioScope { PortfolioScope(rawValue: scopeRaw) ?? .all }
  private var period: PortfolioPeriod { PortfolioPeriod(rawValue: periodRaw) ?? .day }
  private var snapshot: PortfolioSnapshot? { store.snapshot(for: scope) }
  private var connected: Bool {
    if scope == .all { return store.connectedCount > 0 }
    if scope == .wallet { return store.walletCount > 0 }
    return store.cache?.accounts.contains { $0.source == (scope == .pump ? .pump : .fomo) } == true
  }
  private var includesWallet: Bool { scope == .wallet || (scope == .all && store.walletCount > 0) }
  private var refreshing: Bool {
    (scope != .wallet && store.isRefreshing) || (includesWallet && store.isWalletRefreshing)
  }
  private var currentPeriod: Bool { snapshot?.period == period }
  let showSidebar: Bool
  let workspace: WorkspaceStore
  let openMarket: () -> Void
  let openHolding: (PortfolioHolding) -> Void

  var body: some View {
    HStack(spacing: 0) {
      if showSidebar {
        PortfolioSidebarView(
          scope: Binding(get: { scope }, set: { scopeRaw = $0.rawValue }), workspace: workspace,
          openMarket: openMarket)
        Divider()
      }
      VStack(spacing: 0) {
        header
        Divider()
        PortfolioSummaryView(snapshot: snapshot, period: period, isCurrentPeriod: currentPeriod)
        Divider()
        PortfolioHistoryView(
          snapshot: snapshot,
          period: Binding(get: { period }, set: { periodRaw = $0.rawValue }),
          loading: scope != .wallet && store.isRefreshing,
          currentPeriod: currentPeriod,
          connectedAccountsOnly: scope == .all && store.walletCount > 0 && !(snapshot?.history.isEmpty ?? true))
        Divider()
        PortfolioHoldingsView(
          snapshot: snapshot, loading: refreshing, connected: connected, walletScope: scope == .wallet,
          open: openHolding
        )
        .frame(maxHeight: .infinity)
      }
      .frame(minWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(TerminalStyle.canvas)
    .onAppear { store.selectPeriod(period) }
    .onChange(of: period) { _, value in store.selectPeriod(value) }
  }
  private var header: some View {
    HStack(spacing: 16) {
      Text("Portfolio").font(AppTypography.font(size: 22, weight: .semibold))
      Text(subtitle).font(AppTypography.font(size: 14)).foregroundStyle(.secondary).lineLimit(1)
      Button {
        if scope != .wallet { store.refresh() }
        if includesWallet { wallet.refreshBalances() }
      } label: {
        if refreshing {
          ProgressView().controlSize(.mini).frame(width: 32, height: 28)
        } else {
          Image(systemName: "arrow.clockwise").frame(width: 32, height: 28)
        }
      }
      .buttonStyle(TerminalControlStyle(fill: .clear)).disabled(refreshing)
      .help("Refresh portfolio").accessibilityLabel("Refresh portfolio")
      TimelineView(.periodic(from: .now, by: 1)) { context in
        if let timestamp = snapshot?.asOf {
          Text(age(timestamp, at: context.date)).font(AppTypography.font(size: 12)).foregroundStyle(
            .secondary
          )
          .lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if !notices.isEmpty {
        Button {
          showNotices.toggle()
        } label: {
          Label("Data notice", systemImage: "exclamationmark.circle")
          .font(AppTypography.font(size: 12)).foregroundStyle(.orange).padding(.horizontal, 8)
          .frame(
            height: 28)
        }
        .buttonStyle(TerminalControlStyle(fill: .clear))
        .popover(isPresented: $showNotices) {
          VStack(alignment: .leading, spacing: 12) {
            Text("Portfolio data").font(AppTypography.font(size: 16, weight: .semibold))
            ScrollView {
              VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(notices.enumerated()), id: \.offset) { _, message in
                  Text(message).font(AppTypography.font(size: 14)).fixedSize(
                    horizontal: false, vertical: true)
                }
              }
            }.frame(maxHeight: 280)
          }
          .padding(20).frame(width: 380).preferredColorScheme(.dark)
        }
      }
    }
    .padding(.horizontal, 24).frame(height: 64)
  }
  private var subtitle: String {
    if scope != .all { return scope.name }
    let count = store.connectedCount
    if let snapshot, snapshot.sourceCount > 0, snapshot.sourceCount < count {
      return "All accounts · \(snapshot.sourceCount) of \(count) sources loaded"
    }
    return
      "All accounts · \(count) \(store.connectionNotice == nil ? "connected" : "saved") source\(count == 1 ? "" : "s")"
  }
  private var notices: [String] {
    (snapshot?.warnings ?? []) + (store.error.map { [$0] } ?? [])
      + (store.connectionNotice.map { [$0] } ?? [])
  }
  private func age(_ timestamp: Double, at date: Date) -> String {
    let seconds = max(0, Int(date.timeIntervalSince1970 - timestamp))
    let prefix = store.isSaved ? "Saved" : "Updated"
    if seconds < 60 { return "\(prefix) \(seconds)s ago" }
    if seconds < 3600 { return "\(prefix) \(seconds / 60)m ago" }
    return "\(prefix) \(seconds / 3600)h ago"
  }
}
