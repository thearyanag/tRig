import SwiftUI

struct WorkspaceView: View {
  @State private var workspace = WorkspaceStore.shared
  @State private var showSearch = false
  @SceneStorage("workspace.sidebarVisible") private var showSidebar = true
  @State private var draft = TradeDraft()
  @State private var loadedMarketKey: String?
  @State private var marketError: String?
  @State private var resolveID = UUID()

  private var selection: Binding<String?> {
    Binding(
      get: { workspace.isWatched(workspace.selectedAsset) ? workspace.selectedAsset.id : nil },
      set: { if let id = $0 { workspace.openWatched(id) } })
  }

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceTopBar(
        showSidebar: $showSidebar, openSearch: { showSearch = true })
      HStack(spacing: 0) {
        if showSidebar {
          WorkspaceSidebarView(workspace: workspace, selection: selection) { showSearch = true }
            .frame(width: 304)
          Divider()
        }
        tradingLayout(workspace.selectedAsset)
          .frame(minWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .toolbar(.hidden, for: .windowToolbar)
    .ignoresSafeArea(.container, edges: .top)
    .focusedSceneValue(\.openAssetSearch, { showSearch = true })
    .focusedSceneValue(\.workspaceStore, workspace)
    .sheet(isPresented: $showSearch) { AssetSearchView(workspace: workspace) }
    .task(id: String(workspace.selectionVersion) + resolveID.uuidString) { await prepareMarket() }
    .onChange(of: workspace.selectedAsset.id) { _, _ in draft = TradeDraft() }
    .frame(minWidth: 1100, minHeight: 740)
    .preferredColorScheme(.dark)
    .tint(.blue)
  }

  private func tradingLayout(_ asset: Asset) -> some View {
    let ready = loadedMarketKey == asset.id + asset.pool
    let price = ready ? (workspace.lastPrice ?? asset.priceUsd) : nil
    return VStack(spacing: 0) {
      AssetHeaderView(asset: asset, livePrice: price, isLiveMarket: true)
      Divider()
      HSplitView {
        Group {
          if ready {
            ChartPanelView(asset: asset) { workspace.receivePrice($0, for: asset) }
              .id(asset.id + asset.pool)
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
        SwapQuoteTicketView(asset: asset, draft: $draft, referencePrice: price)
          .id(asset.id)
          .frame(minWidth: 280, idealWidth: 300, maxWidth: 320)
      }
      .frame(maxHeight: .infinity)
      Divider()
      TradingDockView()
    }
    .background(TerminalStyle.canvas)
  }

  private func prepareMarket() async {
    let id = workspace.selectedAsset.id
    loadedMarketKey = nil
    marketError = nil
    do {
      let asset = try await AssetDiscoveryClient().resolve(id)
      try Task.checkCancellation()
      guard workspace.selectedAsset.id == id else { return }
      workspace.applyResolved(asset)
      loadedMarketKey = asset.id + asset.pool
    } catch {
      guard !Task.isCancelled, workspace.selectedAsset.id == id else { return }
      marketError = error.localizedDescription
    }
  }
}

#Preview { WorkspaceView().frame(width: 1280, height: 820) }
