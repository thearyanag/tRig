import SwiftUI

struct RecentTradesPanel: View {
  let asset: Asset
  let store: MarketDataStore
  let collapse: () -> Void
  private var feed: RecentTrades? { store.trades.flatMap { $0.matches(asset) ? $0 : nil } }
  private let widths: [CGFloat] = [38, 27, 59, 57, 56]
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Recent trades").font(AppTypography.calloutMedium)
        Spacer(minLength: 2)
        if store.loadingTrades { ProgressView().controlSize(.mini) }
        Button(action: collapse) { Image(systemName: "chevron.right").frame(width: 22, height: 28) }
          .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Hide recent trades")
      }.padding(.horizontal, 8).frame(height: 38)
      Divider()
      HStack(spacing: 0) {
        ForEach(Array(["Time", "Side", "Price", "Qty", "USD"].enumerated()), id: \.offset) {
          index, title in
          Text(title).frame(width: widths[index], alignment: index < 2 ? .leading : .trailing)
        }
      }.font(AppTypography.font(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 8)
        .frame(height: 25)
      Divider()
      if let feed, !feed.rows.isEmpty {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(feed.rows) { row in
              if let url = asset.transactionExplorer(row.transaction) {
                Link(destination: url) { trade(row) }.buttonStyle(.plain)
              } else {
                trade(row)
              }
              Divider().opacity(0.5)
            }
          }
        }
      } else {
        VStack(spacing: 8) {
          if store.loadingTrades { ProgressView().controlSize(.small) }
          Text(
            !asset.hasChart
              ? (asset.marketResolved == true ? "Trades unavailable for this token" : "Checking market coverage…")
              : store.tradesError != nil
                ? "Trades temporarily unavailable"
                : store.loadingTrades ? "Loading trades…" : "No recent trades"
          )
          .font(AppTypography.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      TimelineView(.periodic(from: .now, by: 1)) { context in
        HStack(spacing: 4) {
          if let feed {
            let age = max(0, Int(context.date.timeIntervalSince1970 - feed.fetchedAt))
            Text(age < 60 ? "Updated \(age)s ago" : "Updated \(age / 60)m ago")
              .foregroundStyle(age > 120 ? Color.orange : .secondary)
          } else {
            Text("Recent market trades").foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          if store.tradesError != nil {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(
              store.tradesError ?? "")
          }
        }.font(AppTypography.font(size: 10)).padding(8)
      }
    }.background(TerminalStyle.canvas)
  }
  private func trade(_ row: RecentTrade) -> some View {
    HStack(spacing: 0) {
      cell(time(row), 0, .secondary)
      cell(
        row.side == "buy" ? "Buy" : "Sell", 1,
        row.side == "buy" ? TerminalStyle.buy : TerminalStyle.sell)
      cell(PortfolioFormat.currency(row.priceUsd, price: true), 2)
      cell(compactQuantity(row.quantity), 3)
      cell(PortfolioFormat.currency(row.valueUsd), 4)
    }.font(AppTypography.font(size: 10)).monospacedDigit().padding(.horizontal, 8).frame(height: 25)
      .contentShape(Rectangle()).help(
        "\(row.timestamp) · \(row.quantity) \(asset.symbol) · Open transaction")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(time(row)), \(row.side), \(row.quantity) \(asset.symbol), \(PortfolioFormat.currency(row.priceUsd, price: true)), value \(PortfolioFormat.currency(row.valueUsd))")
  }
  private func time(_ row: RecentTrade) -> String {
    guard let date = row.date else { return "—" }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"; return formatter.string(from: date)
  }
  private func compactQuantity(_ value: String) -> String {
    guard let number = PortfolioFormat.decimal(value) else { return "—" }
    let scales: [(Decimal, String)] = [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
    for (scale, suffix) in scales {
      if number >= scale { return DisplayFormat.number(number / scale, decimals: 2) + suffix }
    }
    if number >= 1 { return DisplayFormat.number(number, decimals: 3) }
    return PortfolioFormat.quantity(value)
  }
  private func cell(_ value: String, _ index: Int, _ color: Color = .primary) -> some View {
    Text(value).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
      .padding(.leading, index >= 2 ? 4 : 0)
      .frame(width: widths[index], alignment: index < 2 ? .leading : .trailing).clipped()
  }
}
