import SwiftUI

struct WorkspaceView: View {
  @Environment(\.openWindow) private var openWindow
  @State private var workspace = WorkspaceStore.shared
  @State private var showSearch = false
  @State private var showTicket = false
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
    NavigationSplitView {
      List(selection: selection) {
        Section("Watchlist") {
          ForEach(workspace.watchlist) { asset in
            Label("\(asset.symbol) · \(asset.name)", systemImage: asset.systemImage)
              .lineLimit(1).tag(asset.id)
              .contextMenu { Button("Remove from watchlist") { workspace.toggleWatch(asset) } }
          }
          if workspace.watchlist.isEmpty {
            Text("Use ⌘K to find an asset").foregroundStyle(.secondary)
          }
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
    } detail: {
      tradingLayout(workspace.selectedAsset)
    }
    .navigationTitle("tRig")
    .toolbar {
      ToolbarItem(placement: .principal) {
        Button {
          showSearch = true
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
            Text("Search assets")
            Text("⌘K").foregroundStyle(.secondary)
          }
        }
        .help("Search by name, ticker or Solana contract address")
      }
      ToolbarItem(placement: .automatic) {
        Text("Chart data · Sample trading").font(.caption).foregroundStyle(.secondary)
      }
      ToolbarItem(placement: .automatic) {
        Toggle("Sample ticket", isOn: $showTicket).toggleStyle(.button)
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          openWindow(id: "components")
        } label: {
          Label("Component Gallery", systemImage: "square.grid.2x2")
        }
        .help("Component Gallery (⇧⌘G)")
      }
    }
    .focusedSceneValue(\.openAssetSearch, { showSearch = true })
    .focusedSceneValue(\.workspaceStore, workspace)
    .sheet(isPresented: $showSearch) { AssetSearchView(workspace: workspace) }
    .task(id: String(workspace.selectionVersion) + resolveID.uuidString) { await prepareMarket() }
    .onChange(of: workspace.selectedAsset.id) { _, _ in draft = TradeDraft() }
    .frame(minWidth: 660, minHeight: 560)
  }

  private func tradingLayout(_ asset: Asset) -> some View {
    let ready = loadedMarketKey == asset.id + asset.pool
    let price = ready ? (workspace.lastPrice ?? asset.priceUsd) : nil
    return VStack(spacing: 0) {
      AssetHeaderView(
        asset: asset, livePrice: price, isLiveMarket: true,
        isWatched: Binding(
          get: { workspace.isWatched(asset) }, set: { _ in workspace.toggleWatch(asset) })
      )
      .padding(20)
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
        if showTicket {
          Group {
            if let price, price.isFinite, price > 0 {
              TradeTicketView(
                asset: asset, market: .preview(price: price), priceLabel: "Reference price",
                draft: $draft
              )
              .id(asset.id)
            } else {
              PlaceholderPanel(
                title: "\(asset.symbol) trade preview", systemImage: "arrow.left.arrow.right",
                message: "Waiting for market data.")
            }
          }
          .frame(minWidth: 280, idealWidth: 300, maxWidth: 340)
        }
      }
      .frame(maxHeight: .infinity)
      Divider()
      VStack(alignment: .leading, spacing: 14) {
        Text("Execution preview").font(.headline)
        Label("No execution wallet connected", systemImage: "wallet.bifold").foregroundStyle(
          .secondary)
      }
      .padding(16).frame(maxWidth: .infinity, alignment: .leading).frame(height: 110)
    }
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
