import SwiftUI

struct WorkspaceView: View {
  @State private var workspace = WorkspaceStore.shared
  @State private var marketData = MarketDataStore()
  @SceneStorage("workspace.tradesVisible") private var showTrades = true
  @Environment(PortfolioStore.self) private var portfolio
  @Environment(\.scenePhase) private var scenePhase
  @Environment(ConnectionStore.self) private var connections
  @Environment(TelegramSession.self) private var telegram
  @SceneStorage("workspace.section") private var sectionRaw = WorkspaceSection.markets.rawValue
  @State private var marketOpenTask: Task<Void, Never>?
  @State private var marketOpenError: String?
  @State private var showSearch = false
  @SceneStorage("workspace.sidebarVisible") private var showSidebar = true
  @SceneStorage("workspace.contextVisible") private var showContext = false
  @State private var draft = TradeDraft()
  @State private var limitDraft = LimitOrderDraft()
  @State private var exitDraft = ExitOrderDraft()
  @State private var loadedMarketKey: String?
  @State private var marketError: String?
  @State private var resolveID = UUID()

  private var section: WorkspaceSection { WorkspaceSection(rawValue: sectionRaw) ?? .markets }
  private var sectionBinding: Binding<WorkspaceSection> {
    Binding(get: { section }, set: { sectionRaw = $0.rawValue })
  }
  private var selection: Binding<String?> {
    Binding(
      get: {
        workspace.isWatched(workspace.selectedAsset) ? workspace.selectedAsset.identity : nil
      },
      set: { if let id = $0 { workspace.openWatched(id) } })
  }

  private var content: some View {
    VStack(spacing: 0) {
      WorkspaceTopBar(
        showSidebar: $showSidebar, section: sectionBinding, openSearch: { showSearch = true })
      if section == .portfolio {
        PortfolioView(
          store: portfolio, showSidebar: showSidebar, workspace: workspace,
          openMarket: { sectionRaw = WorkspaceSection.markets.rawValue }, openHolding: openHolding)
      } else {
        HStack(spacing: 0) {
          if showSidebar {
            WorkspaceSidebarView(workspace: workspace, selection: selection, showContext: $showContext,
              telegram: telegram) { showSearch = true }
              .frame(width: 304)
            Divider()
          }
          tradingLayout(workspace.selectedAsset).frame(
            minWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
  }

  private var marketPollID: String {
    section.rawValue + workspace.selectedAsset.marketKey
      + String(loadedMarketKey == workspace.selectedAsset.marketKey)
      + String(scenePhase != .background)
  }

  var body: some View {
    content
      .task { portfolio.start(connections) }
      .onChange(of: connections.accountSignature) { _, _ in portfolio.connectionChanged() }
      .onChange(of: scenePhase) { _, phase in
        portfolio.isActive = phase == .active
        if phase == .active { portfolio.requestUpdate() }
      }
      .toolbar(.hidden, for: .windowToolbar)
      .ignoresSafeArea(.container, edges: .top)
      .focusedSceneValue(\.openAssetSearch, { showSearch = true })
      .focusedSceneValue(\.workspaceStore, workspace)
      .sheet(isPresented: $showSearch) {
        AssetSearchView(
          workspace: workspace, onOpen: { sectionRaw = WorkspaceSection.markets.rawValue })
      }
      .task(id: section.rawValue + String(workspace.selectionVersion) + resolveID.uuidString) {
        if section == .markets { await prepareMarket() }
      }
      .task(id: marketPollID) { await pollMarket() }
      .onChange(of: workspace.selectedAsset.identity) { _, _ in
        draft = TradeDraft(amountText: workspace.selectedAsset.isSolana ? "100" : "")
        limitDraft = LimitOrderDraft()
        exitDraft = ExitOrderDraft()
        sectionRaw = WorkspaceSection.markets.rawValue
      }
      .alert(
        "Market unavailable",
        isPresented: Binding(
          get: { marketOpenError != nil }, set: { if !$0 { marketOpenError = nil } })
      ) {
        Button("OK") { marketOpenError = nil }
      } message: {
        Text(marketOpenError ?? "")
      }
      .frame(minWidth: showSidebar && showTrades ? 1280 : 1100, minHeight: 740)
      .preferredColorScheme(.dark)
      .tint(.blue)
  }

  private func tradingLayout(_ asset: Asset) -> some View {
    let ready = loadedMarketKey == asset.marketKey
    let snapshot = marketData.snapshot.flatMap { $0.matches(asset) ? $0 : nil }
    let price = ready ? (workspace.lastPrice ?? snapshot?.asset.priceUsd ?? asset.priceUsd) : nil
    return VStack(spacing: 0) {
      AssetHeaderView(
        asset: asset, livePrice: price, isLiveMarket: true, snapshot: snapshot,
        tradesVisible: showTrades, toggleTrades: { showTrades.toggle() },
        marketError: marketData.snapshotError,
        showTelegramDiscussion: telegram.isConnected ? {
          showSidebar = true
          showContext = true
        } : nil)
      Divider()
      HSplitView {
        Group {
          if ready && asset.hasChart {
            ChartPanelView(
              asset: asset,
              draftLines: exitDraft.isEnabled
                ? exitDraft.chartLines(asset: asset)
                : [limitDraft.chartLine(asset: asset, side: draft.side)],
              onDraftPriceChange: { id, value, revision in
                if id == "limit" {
                  limitDraft.receiveChartPrice(value, revision: revision)
                } else {
                  exitDraft.receiveChartPrice(id: id, value: value, revision: revision)
                }
              }, onPriceChange: { workspace.receivePrice($0, for: asset) }
            )
            .id(asset.marketKey)
          } else if ready && !asset.hasChart {
            PlaceholderPanel(
              title: "Chart unavailable", systemImage: "chart.xyaxis.line",
              message:
                "No chart is available for this token. Supported quotes remain accessible in the ticket."
            )
          } else if let marketError {
            VStack(spacing: 14) {
              PlaceholderPanel(
                title: "Market unavailable", systemImage: "wifi.exclamationmark",
                message: marketError)
              Button("Retry") { resolveID = UUID() }.padding(.bottom, 24)
            }
          } else {
            VStack(spacing: 12) {
              ProgressView()
              Text("Opening \(asset.symbol)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .frame(minWidth: 440, minHeight: 320)
        if showTrades {
          RecentTradesPanel(asset: asset, store: marketData, collapse: { showTrades = false })
            .frame(minWidth: 253, idealWidth: 260, maxWidth: 280)
        }
        SwapQuoteTicketView(
          asset: asset, draft: $draft, limitDraft: $limitDraft, exitDraft: $exitDraft,
          referencePrice: price
        )
        .id(asset.identity)
        .frame(minWidth: 280, idealWidth: 300, maxWidth: 320)
      }
      .frame(maxHeight: .infinity)
      Divider()
      TradingDockView(
        portfolio: portfolio, selectedMint: asset.isSolana ? asset.id : "", openHolding: openHolding
      )
    }
    .background(TerminalStyle.canvas)
  }

  private func pollMarket() async {
    let asset = workspace.selectedAsset
    marketData.select(asset)
    guard section == .markets, scenePhase != .background, loadedMarketKey == asset.marketKey else {
      return
    }
    while !Task.isCancelled {
      await marketData.refresh(asset)
      do { try await Task.sleep(for: .seconds(60)) } catch { break }
    }
  }

  private func openHolding(_ row: PortfolioHolding) {
    guard let mint = row.marketMint else { return }
    marketOpenTask?.cancel()
    marketOpenTask = Task {
      do {
        let asset = try await AssetDiscoveryClient().resolve(mint)
        try Task.checkCancellation()
        workspace.open(asset)
        sectionRaw = WorkspaceSection.markets.rawValue
      } catch {
        guard !Task.isCancelled else { return }
        marketOpenError =
          "This asset could not be opened in Markets. Try searching its contract address."
      }
    }
  }

  private func prepareMarket() async {
    let selected = workspace.selectedAsset
    let id = selected.identity
    loadedMarketKey = selected.hasChart && selected.marketRouteVersion == 2 ? selected.marketKey : nil
    marketError = nil
    do {
      let asset = try await AssetDiscoveryClient().resolve(selected.id, chain: selected.chainID)
      try Task.checkCancellation()
      guard workspace.selectedAsset.identity == id else { return }
      workspace.applyResolved(asset)
      loadedMarketKey = asset.marketKey
    } catch {
      guard !Task.isCancelled, workspace.selectedAsset.identity == id else { return }
      marketError = error.localizedDescription
    }
  }
}

#Preview {
  WorkspaceView().environment(ConnectionStore()).environment(PortfolioStore())
    .environment(TelegramSession.shared).frame(
    width: 1400, height: 900)
}
