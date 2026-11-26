import AppKit
import SwiftUI

struct PortfolioHoldingsView: View {
  let snapshot: PortfolioSnapshot?
  let loading: Bool
  let connected: Bool
  var walletScope = false
  let open: (PortfolioHolding) -> Void
  @Environment(\.openWorkspaceSettings) private var openSettings
  @State private var search = ""
  @State private var hideSmall = false
  @State private var sort: PortfolioSort = .valueDescending
  @State private var expanded: Set<String> = []
  @State private var selected: String?
  @FocusState private var tableFocused: Bool
  private var rows: [PortfolioHolding] {
    (snapshot?.holdings ?? []).filter { row in
      let matches =
        search.isEmpty
        || [row.name, row.symbol, row.mint, PortfolioFormat.chainName(row.chain)].contains {
          $0.localizedCaseInsensitiveContains(search)
        }
      return matches
        && (!hideSmall || PortfolioFormat.decimal(row.valueUsd).map { $0 >= 1 } != false)
    }.sorted { a, b in
      if sort == .asset { return a.symbol.localizedStandardCompare(b.symbol) == .orderedAscending }
      let left = PortfolioFormat.decimal(sort == .pnl ? a.pnlUsd : a.valueUsd)
      let right = PortfolioFormat.decimal(sort == .pnl ? b.pnlUsd : b.valueUsd)
      if left == right { return a.id < b.id }
      if left == nil { return false }
      if right == nil { return true }
      return sort == .valueAscending ? left! < right! : left! > right!
    }
  }
  private let weights: [CGFloat] = [0.21, 0.13, 0.12, 0.105, 0.12, 0.105, 0.12, 0.09]

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      GeometryReader { geometry in
        let width = max(940, geometry.size.width)
        let inner = width - 48
        ScrollView([.horizontal, .vertical]) {
          LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
              ForEach(rows) { row in
                holdingRow(row, width: inner)
                if expanded.contains(row.id) {
                  ForEach(row.lots) { lot in lotRow(lot, width: inner) }
                }
              }
            } header: {
              columns(width: inner)
            }
          }
          .frame(width: width, alignment: .topLeading)
        }
        .focusable().focused($tableFocused).focusEffectDisabled()
        .onKeyPress(.downArrow) {
          move(1)
          return .handled
        }
        .onKeyPress(.upArrow) {
          move(-1)
          return .handled
        }
        .onKeyPress(.return) {
          if let row = rows.first(where: { $0.id == selected }), row.marketMint != nil { open(row) }
          return .handled
        }
        .overlay {
          if rows.isEmpty {
            VStack(spacing: 10) {
              if loading {
                ProgressView().controlSize(.small)
              } else {
                Image(systemName: connected ? "tray" : "link").font(.title2).foregroundStyle(
                  .secondary)
              }
              Text(emptyTitle).font(AppTypography.font(size: 16, weight: .semibold))
              Text(emptyMessage).font(AppTypography.font(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
              if !connected && !walletScope {
                Button("Open Settings") { openSettings(.connections) }.buttonStyle(.bordered)
              }
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
      HStack {
        Text("Showing \(rows.count) of \(snapshot?.holdings.count ?? 0) assets")
        Spacer()
        Text("Read only")
      }
      .font(AppTypography.font(size: 12)).foregroundStyle(.secondary)
      .padding(.horizontal, 24).frame(height: 28)
    }
    .onChange(of: snapshot?.scope) { _, _ in
      selected = nil
      expanded = []
    }
  }
  private var toolbar: some View {
    HStack(spacing: 16) {
      Text("Holdings").font(AppTypography.font(size: 17, weight: .semibold))
      Text("\(snapshot?.holdings.count ?? 0)").font(AppTypography.font(size: 14)).foregroundStyle(
        .secondary)
      HStack(spacing: 9) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search assets", text: $search).textFieldStyle(.plain).font(
          AppTypography.font(size: 14)
        )
        .accessibilityLabel("Search portfolio assets")
      }
      .padding(.horizontal, 10).frame(maxWidth: 360).frame(height: 34)
      .background(TerminalStyle.field, in: RoundedRectangle(cornerRadius: 4))
      .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(TerminalStyle.border))
      Spacer(minLength: 4)
      Toggle("Hide small balances", isOn: $hideSmall).toggleStyle(.checkbox)
        .font(AppTypography.font(size: 14)).fixedSize()
        .help("Hide priced assets worth less than $1. Unpriced assets remain visible.")
      Divider().frame(height: 22)
      Menu {
        ForEach(PortfolioSort.allCases) { value in Button(value.rawValue) { sort = value } }
      } label: {
        Text("Sort: \(sort.rawValue)").font(AppTypography.font(size: 14))
      }
      .menuStyle(.borderlessButton).fixedSize().help("Sort portfolio holdings")
    }
    .padding(.horizontal, 24).frame(height: 62)
  }
  private func columns(width: CGFloat) -> some View {
    HStack(spacing: 0) {
      ForEach(
        Array(
          ["Asset", "Source", "Quantity", "Price", "Value", "Avg. entry", "P&L ($)", "P&L (%)"]
            .enumerated()), id: \.offset
      ) { index, title in
        Text(title).frame(
          width: width * weights[index], alignment: index < 2 ? .leading : .trailing)
      }
    }
    .font(AppTypography.font(size: 12)).foregroundStyle(.secondary)
    .padding(.horizontal, 24).frame(height: 36)
    .background(TerminalStyle.canvas)
    .overlay(alignment: .bottom) { Divider().padding(.horizontal, 24) }
  }
  private func holdingRow(_ row: PortfolioHolding, width: CGFloat) -> some View {
    HStack(spacing: 0) {
      HStack(spacing: 10) {
        TokenArtworkView(mint: row.mint, name: row.name, symbol: row.symbol, imageURL: row.imageUrl)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 5) {
            Text(row.symbol).font(AppTypography.font(size: 14, weight: .medium)).lineLimit(1)
            if !row.warnings.isEmpty {
              Image(systemName: "exclamationmark.circle").font(AppTypography.font(size: 12))
                .foregroundStyle(.orange).help(row.warnings.joined(separator: "\n"))
            }
          }
          Text("\(row.name) · \(PortfolioFormat.chainName(row.chain))").font(
            AppTypography.font(size: 12)
          )
          .foregroundStyle(.secondary).lineLimit(1)
        }
      }.frame(width: width * weights[0], alignment: .leading)
      source(row, width: width * weights[1])
      cell(PortfolioFormat.quantity(row.quantity), width: width * weights[2], help: row.quantity)
      cell(PortfolioFormat.currency(row.priceUsd, price: true), width: width * weights[3])
      cell(PortfolioFormat.currency(row.valueUsd), width: width * weights[4])
      cell(PortfolioFormat.currency(row.averageEntryUsd, price: true), width: width * weights[5])
      pnlCell(row.pnlUsd, width: width * weights[6])
      cell(
        PortfolioFormat.percent(row.pnlPercent) ?? "—", width: width * weights[7],
        color: pnlColor(row.pnlUsd))
    }
    .padding(.horizontal, 24).frame(height: 52)
    .background(selected == row.id ? TerminalStyle.accent.opacity(0.13) : .clear)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { if row.marketMint != nil { open(row) } }
    .onTapGesture {
      selected = row.id
      tableFocused = true
    }
    .contextMenu {
      Button("Open in Markets") { open(row) }.disabled(row.marketMint == nil)
      Button("Copy token address") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.mint, forType: .string)
      }
    }
    .overlay(alignment: .bottom) { Divider().padding(.horizontal, 24) }
    .accessibilityElement(children: .contain)
  }
  private func source(_ row: PortfolioHolding, width: CGFloat) -> some View {
    Group {
      if row.lots.count > 1 || row.sources.count > 1 {
        Button {
          if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
        } label: {
          HStack(spacing: 5) {
            Text(row.sources.map(\.name).joined(separator: " · ")).lineLimit(2)
            Image(systemName: expanded.contains(row.id) ? "chevron.up" : "chevron.down").font(
              .system(size: 8))
          }.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(
          "\(expanded.contains(row.id) ? "Collapse" : "Expand") \(row.symbol) account breakdown")
      } else {
        Text(row.sources.map(\.name).joined(separator: " · ")).lineLimit(1)
      }
    }
    .font(AppTypography.font(size: 12)).foregroundStyle(.secondary)
    .frame(width: width, alignment: .leading)
  }
  private func lotRow(_ lot: PortfolioLot, width: CGFloat) -> some View {
    HStack(spacing: 0) {
      Text("Account balance").font(AppTypography.font(size: 12)).foregroundStyle(.secondary)
        .padding(.leading, 38).frame(width: width * weights[0], alignment: .leading)
      Text(lot.sources.map(\.name).joined(separator: " · ")).font(AppTypography.font(size: 12))
        .frame(width: width * weights[1], alignment: .leading)
      cell(PortfolioFormat.quantity(lot.quantity), width: width * weights[2])
      cell(PortfolioFormat.currency(lot.priceUsd, price: true), width: width * weights[3])
      cell(PortfolioFormat.currency(lot.valueUsd), width: width * weights[4])
      cell(PortfolioFormat.currency(lot.averageEntryUsd, price: true), width: width * weights[5])
      pnlCell(lot.pnlUsd, width: width * weights[6])
      cell(
        PortfolioFormat.percent(lot.pnlPercent) ?? "—", width: width * weights[7],
        color: pnlColor(lot.pnlUsd))
    }
    .padding(.horizontal, 24).frame(height: 38).background(TerminalStyle.field.opacity(0.5))
    .overlay(alignment: .bottom) { Divider().padding(.horizontal, 24) }
  }
  private func cell(_ text: String, width: CGFloat, color: Color = .primary, help: String? = nil)
    -> some View
  {
    Text(text).font(AppTypography.font(size: 14)).monospacedDigit().foregroundStyle(color)
      .lineLimit(1).minimumScaleFactor(0.65).frame(width: width, alignment: .trailing)
      .help(help ?? text)
  }
  private func pnlCell(_ value: String?, width: CGFloat) -> some View {
    cell(PortfolioFormat.currency(value, signed: true), width: width, color: pnlColor(value))
  }
  private func pnlColor(_ value: String?) -> Color {
    guard let n = PortfolioFormat.decimal(value), n != 0 else { return .secondary }
    return n > 0 ? TerminalStyle.buy : TerminalStyle.sell
  }
  private func move(_ direction: Int) {
    guard !rows.isEmpty else { return }
    let index = rows.firstIndex { $0.id == selected } ?? (direction > 0 ? -1 : rows.count)
    selected = rows[min(rows.count - 1, max(0, index + direction))].id
  }
  private var emptyTitle: String {
    if loading { return "Loading holdings…" }
    if !connected { return walletScope ? "Add a tRig wallet" : "Connect an account" }
    if !search.isEmpty || hideSmall { return "No matching assets" }
    if snapshot == nil || snapshot?.sourceCount == 0 { return "Portfolio unavailable" }
    return "No holdings"
  }
  private var emptyMessage: String {
    if loading { return walletScope ? "Reading wallet balances." : "Reading account balances." }
    if !connected {
      return walletScope ? "Create or import a wallet from the Wallet menu."
        : "Use a tRig wallet or connect Pumpfun or Fomo in Settings to view your portfolio."
    }
    if !search.isEmpty || hideSmall { return "Try another search or include small balances." }
    if snapshot == nil || snapshot?.sourceCount == 0 {
      return "Open the data notice for details, then refresh to retry."
    }
    return "The selected accounts returned no current holdings."
  }
}
