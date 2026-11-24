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
  private let rowHeight: CGFloat = 46
  private let rowSpacing: CGFloat = 2

  private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var displayed: [Asset] {
    if submittedQuery == term { return results }
    return workspace.watchlist.filter {
      (chain == "all" || $0.chainID == chain)
        && (term.isEmpty || $0.symbol.localizedCaseInsensitiveContains(term)
          || $0.name.localizedCaseInsensitiveContains(term) || $0.id == term)
    }
  }
  private var selected: Asset? {
    guard error == nil else { return nil }
    return displayed.first { $0.identity == selection }
  }
  private var networkName: String {
    networks.networks.first { $0.id == chain }?.name
      ?? (chain == "solana" ? "Solana" : chain == "all" ? "All networks" : chain)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      searchField
        .padding(.horizontal, 16).padding(.vertical, 12)
      Divider()
      resultsContent
      Divider()
      footer
    }
    .font(AppTypography.body)
    .frame(width: 560)
    .presentationBackground {
      WorkspaceChrome(region: .toolbar)
    }
    .defaultFocus($searchFocused, true)
    .onAppear {
      chain = initialChain
      selection = displayed.first?.identity
    }
    .task {
      // Let the sheet install its first responder before requesting text focus.
      await Task.yield()
      guard !Task.isCancelled else { return }
      searchFocused = true
      await networks.load()
    }
    .onChange(of: query) { _, _ in resetSearch() }
    .onChange(of: chain) { _, _ in resetSearch() }
    .onDisappear { requestTask?.cancel() }
  }

  private var searchField: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField("Search tokens or paste a CA…", text: $query)
        .textFieldStyle(.plain)
        .font(AppTypography.font(size: 16, weight: .medium))
        .focused($searchFocused)
        .accessibilityLabel("Asset search")
        .onSubmit(primaryAction)
        .onKeyPress(.downArrow) {
          move(1)
          return .handled
        }
        .onKeyPress(.upArrow) {
          move(-1)
          return .handled
        }
      Menu {
        Picker("Network", selection: $chain) {
          Text("All networks").tag("all")
          if !networks.networks.contains(where: { $0.id == "solana" }) {
            Text("Solana").tag("solana")
          }
          ForEach(networks.networks) { Text($0.name).tag($0.id) }
        }
        .pickerStyle(.inline)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .medium))
          Text(networkName).lineLimit(1)
          Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .font(AppTypography.caption)
        .padding(.horizontal, 8).frame(height: 26)
        .background(TerminalStyle.canvas.opacity(0.65), in: Capsule())
        .terminalGlass(.init(cornerRadius: 13))
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("Network")
      .accessibilityValue(networkName)
    }
    .padding(.horizontal, 10).frame(height: 38)
    .background(TerminalStyle.field.opacity(0.68), in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9).strokeBorder(
        searchFocused ? TerminalStyle.accent.opacity(0.56) : TerminalStyle.border)
    }
  }

  @ViewBuilder private var resultsContent: some View {
    if let error {
      message("Search unavailable", detail: error)
    } else if displayed.isEmpty {
      if isLoading {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Searching markets…")
        }
        .font(AppTypography.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
      } else if submittedQuery == term {
        message("No matching assets", detail: "Try a different name or contract address.")
      } else if term.isEmpty {
        message("Find an asset", detail: "Search by name, ticker, or contract address.")
      } else {
        message("Search markets", detail: "Press Return to look up this asset.")
      }
    } else {
      let rows = min(displayed.count, 6)
      HStack {
        Text(submittedQuery == term ? "Results" : "Watchlist")
        Spacer()
        if isLoading {
          ProgressView().controlSize(.mini).accessibilityLabel("Searching markets")
        }
      }
      .font(AppTypography.caption).foregroundStyle(.secondary)
      .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: rowSpacing) {
            ForEach(displayed, id: \.identity) { asset in
              AssetSearchResultRow(
                asset: asset, selected: asset.identity == selection,
                watched: workspace.isWatched(asset), height: rowHeight
              ) { open(asset) }
              .id(asset.identity)
            }
          }.padding(.horizontal, 10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: selection) { _, value in
          if let value { proxy.scrollTo(value) }
        }
      }
      .frame(height: CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing)
      .padding(.bottom, 8)
    }
  }

  private func message(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(AppTypography.calloutMedium)
      Text(detail).font(AppTypography.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Text("↑ ↓").monospacedDigit().accessibilityHidden(true)
      Text("Navigate").padding(.trailing, 6)
      Button("Esc") { dismiss() }
        .buttonStyle(.plain).keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close asset search")
      Spacer()
      if !term.isEmpty && selected != nil && submittedQuery != term {
        Button("Search markets") { search() }
          .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
          .disabled(isLoading).help("Search markets (⌘ Return)")
      }
      Button(action: primaryAction) {
        HStack(spacing: 8) {
          Text(selected == nil ? "Search" : "Open")
          Text("↵").accessibilityHidden(true)
        }
        .font(AppTypography.caption)
        .frame(height: 25).padding(.horizontal, 10)
        .foregroundStyle(.white)
        .background(TerminalStyle.accent.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
      }
      .buttonStyle(.plain).disabled(isLoading || (selected == nil && term.isEmpty))
      .opacity(isLoading || (selected == nil && term.isEmpty) ? 0.44 : 1)
      .accessibilityLabel(selected == nil ? "Search markets" : "Open asset")
    }
    .font(AppTypography.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 16).frame(height: 39)
  }

  private func resetSearch() {
    requestTask?.cancel()
    generation = UUID()
    submittedQuery = nil
    results = []
    isLoading = false
    error = nil
    selection = displayed.first?.identity
  }

  private func primaryAction() {
    guard !isLoading else { return }
    if let selected { open(selected) } else { search() }
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

private struct AssetSearchResultRow: View {
  let asset: Asset
  let selected: Bool
  let watched: Bool
  let height: CGFloat
  let open: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: open) {
      HStack(spacing: 10) {
        AssetIconView(asset: asset, size: 26)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(asset.symbol).font(AppTypography.calloutMedium)
            Text(asset.name).font(AppTypography.callout).foregroundStyle(.secondary)
          }.lineLimit(1)
          HStack(spacing: 5) {
            Text(asset.shortAddress).monospacedDigit()
            if !asset.hasChart {
              Text(asset.marketResolved == true || asset.marketNetwork == nil
                ? "· Chart unavailable" : "· Market details on open")
            }
            if asset.marketQuotes == false { Text("· Quotes unavailable") }
          }
          .font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 6)
        Text(asset.network).font(AppTypography.caption).foregroundStyle(.secondary)
          .padding(.horizontal, 7).padding(.vertical, 3)
          .background(TerminalStyle.field.opacity(0.7), in: Capsule())
        Image(systemName: watched ? "star.fill" : "arrow.turn.down.left")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(watched ? Color.yellow : .secondary)
          .opacity(watched || selected ? 1 : 0)
          .frame(width: 16)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 10).frame(height: height)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      selected ? TerminalStyle.accent.opacity(0.20) : Color.white.opacity(hovered ? 0.06 : 0),
      in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9).strokeBorder(
        selected ? TerminalStyle.accent.opacity(0.32) : .clear)
    }
    .onHover { hovered = $0 }
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityHint(watched ? "On your watchlist" : "")
    .help(asset.id)
  }
}
