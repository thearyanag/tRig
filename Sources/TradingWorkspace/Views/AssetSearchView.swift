import SwiftUI

struct AssetSearchView: View {
  let workspace: WorkspaceStore
  var onOpen: () -> Void = {}
  var initialChain = "all"
  var onSelect: ((Asset) -> Void)? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var results: [Asset] = []
  @State private var submittedQuery: String?
  @State private var selection: String?
  @State private var isLoading = false
  @State private var error: String?
  @State private var generation = UUID()
  @State private var requestTask: Task<Void, Never>?
  @State private var networks = MarketNetworkStore()
  @State private var chain = "all"
  @FocusState private var searchFocused: Bool

  private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var displayed: [Asset] {
    if submittedQuery == term { return results }
    return workspace.watchlist.filter {
      (chain == "all" || $0.chainID == chain)
        && (term.isEmpty || $0.symbol.localizedCaseInsensitiveContains(term)
          || $0.name.localizedCaseInsensitiveContains(term) || $0.id == term)
    }
  }
  private var selected: Asset? { displayed.first { $0.identity == selection } }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("Search assets", systemImage: "magnifyingglass").font(AppTypography.title2Semibold)
        Spacer()
        Picker("Network", selection: $chain) {
          Text("All networks").tag("all")
          if !networks.networks.contains(where: { $0.id == "solana" }) {
            Text("Solana").tag("solana")
          }
          ForEach(networks.networks) { Text($0.name).tag($0.id) }
        }.frame(width: 180)
      }
      TextField("Name, ticker or contract address", text: $query)
        .textFieldStyle(.roundedBorder).controlSize(.large)
        .focused($searchFocused)
        .accessibilityLabel("Asset search")
        .onSubmit {
          if let selected { open(selected) } else { search() }
        }
        .onKeyPress(.downArrow) {
          move(1)
          return .handled
        }
        .onKeyPress(.upArrow) {
          move(-1)
          return .handled
        }
        .onChange(of: query) { _, _ in
          requestTask?.cancel()
          generation = UUID()
          isLoading = false
          error = nil
          submittedQuery = nil
          selection = displayed.first?.identity
        }
      HStack {
        if isLoading {
          ProgressView().controlSize(.small)
          Text("Searching…")
        } else {
          Text(
            submittedQuery == term
              ? "\(displayed.count) matching assets"
              : "Watchlist · Return to open, or search for more")
        }
        Spacer()
        Button("Search") { search() }.disabled(term.isEmpty || isLoading)
      }
      .font(AppTypography.caption).foregroundStyle(.secondary)

      if let error {
        ContentUnavailableView(
          "Search unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
      } else if displayed.isEmpty {
        ContentUnavailableView(
          submittedQuery == term ? "No matching assets" : "Find an asset",
          systemImage: "magnifyingglass",
          description: Text(
            submittedQuery == term
              ? "Try a different name or paste the contract address."
              : "Enter a name, ticker or contract address, then press Return.")
        )
      } else {
        List(displayed, id: \.identity, selection: $selection) { asset in
          HStack(spacing: 12) {
            AssetIconView(asset: asset, size: 24)
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(asset.symbol).fontWeight(.semibold)
                Text(asset.name).foregroundStyle(.secondary).lineLimit(1)
                Text(asset.network).font(AppTypography.caption).padding(.horizontal, 5).padding(
                  .vertical, 2
                )
                .background(TerminalStyle.panel)
              }
              HStack {
                Text(asset.shortAddress).monospacedDigit()
                if !asset.hasChart { Text(asset.marketResolved == true || asset.marketNetwork == nil
                  ? "· Chart unavailable" : "· Market details on open") }
                if asset.marketQuotes == false { Text("· Quotes unavailable") }
              }.font(AppTypography.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if workspace.isWatched(asset) {
              Image(systemName: "star.fill").foregroundStyle(.yellow)
            }
          }
          .padding(.vertical, 5).tag(asset.identity)
          .contentShape(Rectangle()).onTapGesture(count: 2) { open(asset) }
          .help(asset.id)
        }
        .listStyle(.inset)
      }
      HStack {
        Text("↑ ↓ to select · Return to open").font(AppTypography.caption).foregroundStyle(
          .secondary)
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Open asset") { if let selected { open(selected) } }
          .buttonStyle(.borderedProminent).disabled(selected == nil || isLoading)
      }
    }
    .font(AppTypography.body)
    .padding(24).frame(width: 620, height: 490)
    .onAppear {
      chain = initialChain
      selection = displayed.first?.identity
      searchFocused = true
    }
    .task { await networks.load() }
    .onChange(of: chain) { _, _ in
      requestTask?.cancel()
      generation = UUID()
      submittedQuery = nil
      results = []
      isLoading = false
      error = nil
      selection = displayed.first?.identity
    }
    .onDisappear { requestTask?.cancel() }
  }

  private func search() {
    guard !term.isEmpty else { return }
    requestTask?.cancel()
    let token = UUID()
    generation = token
    let submitted = term
    let submittedChain = chain
    isLoading = true
    error = nil
    requestTask = Task {
      do {
        let found = try await AssetDiscoveryClient().search(submitted, chain: submittedChain)
        guard !Task.isCancelled, generation == token, term == submitted else { return }
        results = found
        submittedQuery = submitted
        selection = found.first?.identity
        isLoading = false
      } catch {
        guard !Task.isCancelled, generation == token else { return }
        isLoading = false
        self.error = error.localizedDescription
      }
    }
  }
  private func move(_ offset: Int) {
    guard !displayed.isEmpty else { return }
    let index =
      displayed.firstIndex { $0.identity == selection } ?? (offset > 0 ? -1 : displayed.count)
    selection = displayed[min(displayed.count - 1, max(0, index + offset))].identity
  }
  private func open(_ asset: Asset) {
    if let onSelect {
      onSelect(asset)
    } else {
      workspace.open(asset)
      onOpen()
    }
    dismiss()
  }
}
