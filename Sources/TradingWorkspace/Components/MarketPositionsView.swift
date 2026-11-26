import SwiftUI

/// Global holdings from the repository; Portfolio filters never narrow this view.
struct MarketPositionsView: View {
  let snapshot: PortfolioSnapshot?
  let selectedChain: String
  let selectedMint: String
  let loading: Bool
  let open: (PortfolioHolding) -> Void
  @State private var expanded: Set<String> = []
  private var rows: [PortfolioHolding] {
    (snapshot?.holdings ?? []).sorted {
      let left = isSelected($0)
      let right = isSelected($1)
      if left != right { return left }
      let a = PortfolioFormat.decimal($0.valueUsd)
      let b = PortfolioFormat.decimal($1.valueUsd)
      if a == b { return $0.id < $1.id }
      if a == nil { return false }
      if b == nil { return true }
      return a! > b!
    }
  }
  private let weights: [CGFloat] = [0.27, 0.16, 0.14, 0.14, 0.15, 0.14]
  var body: some View {
    GeometryReader { geometry in
      let width = max(720, geometry.size.width) - 32
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          ForEach(
            Array(
              ["Asset / source", "Quantity", "Avg. entry", "Price", "P&L", "Value"].enumerated()),
            id: \.offset
          ) { i, name in
            Text(name).frame(width: width * weights[i], alignment: i == 0 ? .leading : .trailing)
          }
        }.font(AppTypography.font(size: 11)).foregroundStyle(.secondary).frame(height: 25).padding(
          .horizontal, 16)
        Divider().padding(.horizontal, 16)
        if rows.isEmpty {
          VStack(spacing: 5) {
            Text(
              loading
                ? "Loading positions…"
                : snapshot?.sourceCount == 0 ? "Positions unavailable" : "No holdings"
            )
            .font(AppTypography.calloutMedium)
            Text("Holdings from your tRig wallet and connected accounts appear here.").font(
              AppTypography.caption
            ).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(rows) { row in
                HStack(spacing: 0) {
                  HStack(spacing: 8) {
                    TokenArtworkView(
                      mint: row.mint, name: row.name, symbol: row.symbol, imageURL: row.imageUrl,
                      size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                      Text(row.symbol).font(AppTypography.font(size: 12, weight: .medium))
                        .lineLimit(1)
                      Button {
                        if expanded.contains(row.id) {
                          expanded.remove(row.id)
                        } else {
                          expanded.insert(row.id)
                        }
                      } label: {
                        HStack(spacing: 4) {
                          Text(row.sources.map(\.name).joined(separator: " · ")).lineLimit(1)
                          Image(
                            systemName: expanded.contains(row.id) ? "chevron.up" : "chevron.down"
                          ).font(.system(size: 7))
                        }
                      }.buttonStyle(.plain).font(AppTypography.font(size: 10)).foregroundStyle(
                        .secondary
                      )
                      .accessibilityLabel(
                        "\(expanded.contains(row.id) ? "Collapse" : "Expand") \(row.symbol) position sources"
                      )
                    }
                  }.frame(width: width * weights[0], alignment: .leading)
                  cells(
                    quantity: row.quantity, entry: row.averageEntryUsd, price: row.priceUsd,
                    pnl: row.pnlUsd, value: row.valueUsd, width: width)
                }
                .padding(.horizontal, 16).frame(height: 40)
                .background(
                  isSelected(row) ? TerminalStyle.accent.opacity(0.10) : .clear
                )
                .contentShape(Rectangle()).onTapGesture(count: 2) {
                  if row.marketMint != nil { open(row) }
                }
                .contextMenu {
                  Button("Open in Markets") { open(row) }.disabled(row.marketMint == nil)
                }
                if expanded.contains(row.id) {
                  ForEach(row.lots) { lot in
                    HStack(spacing: 0) {
                      Text(lot.sources.map(\.name).joined(separator: " · ")).font(
                        AppTypography.font(size: 11)
                      ).foregroundStyle(.secondary)
                        .padding(.leading, 30).frame(width: width * weights[0], alignment: .leading)
                      cells(
                        quantity: lot.quantity, entry: lot.averageEntryUsd, price: lot.priceUsd,
                        pnl: lot.pnlUsd, value: lot.valueUsd, width: width)
                    }.padding(.horizontal, 16).frame(height: 28).background(
                      TerminalStyle.field.opacity(0.5))
                  }
                }
                Divider().padding(.horizontal, 16)
              }
            }
          }
        }
      }
    }
  }
  private func isSelected(_ row: PortfolioHolding) -> Bool {
    guard row.chain == selectedChain, let mint = row.marketMint else { return false }
    return selectedChain == "solana" ? mint == selectedMint
      : mint.caseInsensitiveCompare(selectedMint) == .orderedSame
  }

  private func cells(
    quantity: String?, entry: String?, price: String?, pnl: String?, value: String?, width: CGFloat
  ) -> some View {
    HStack(spacing: 0) {
      number(PortfolioFormat.quantity(quantity), width: width * weights[1])
      number(PortfolioFormat.currency(entry, price: true), width: width * weights[2])
      number(PortfolioFormat.currency(price, price: true), width: width * weights[3])
      number(
        PortfolioFormat.currency(pnl, signed: true), width: width * weights[4], color: color(pnl))
      number(PortfolioFormat.currency(value), width: width * weights[5])
    }
  }
  private func number(_ text: String, width: CGFloat, color: Color = .primary) -> some View {
    Text(text).font(AppTypography.font(size: 12)).monospacedDigit().foregroundStyle(color)
      .lineLimit(1).minimumScaleFactor(0.65).frame(width: width, alignment: .trailing).help(text)
  }
  private func color(_ value: String?) -> Color {
    guard let n = PortfolioFormat.decimal(value), n != 0 else { return .secondary }
    return n > 0 ? TerminalStyle.buy : TerminalStyle.sell
  }
}
