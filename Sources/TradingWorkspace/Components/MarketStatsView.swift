import SwiftUI

struct MarketStatsView: View {
  let asset: Asset
  var market: SampleMarket?
  var livePrice: Double?
  var isLiveMarket: Bool
  var snapshot: MarketSnapshot? = nil
  private var current: Asset { snapshot?.asset ?? asset }

  var body: some View {
    HStack(spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(price).font(AppTypography.font(size: 28, weight: .semibold)).monospacedDigit()
          .lineLimit(1).minimumScaleFactor(0.7)
        if isLiveMarket, let change = current.change24h, change.isFinite {
          Text("\(change > 0 ? "+" : "")\(DisplayFormat.number(Decimal(change), decimals: 2))%")
            .font(AppTypography.calloutMedium).foregroundStyle(
              change >= 0 ? TerminalStyle.buy : TerminalStyle.sell
            )
            .help("24-hour price change")
        } else if !isLiveMarket, let market {
          Text(
            "\(market.changePercent >= 0 ? "+" : "")\(DisplayFormat.number(market.changePercent, decimals: 2))%"
          )
          .foregroundStyle(market.changePercent >= 0 ? Color.green : .red)
          .font(AppTypography.calloutMedium)
        }
      }
      Spacer(minLength: 0)
      metric("24h High", value: snapshot?.high24h.map(formatPrice))
      Divider().frame(height: 30)
      metric("24h Low", value: snapshot?.low24h.map(formatPrice))
      Divider().frame(height: 30)
      metric(isLiveMarket ? "24h Volume" : "24h Volume (sample)", value: volume)
      if isLiveMarket {
        Divider().frame(height: 30)
        metric(
          "Market cap",
          value: current.marketCapUsd.map { DisplayFormat.compactCurrency(Decimal($0)) })
        metric("FDV", value: current.fdvUsd.map { DisplayFormat.compactCurrency(Decimal($0)) })
        metric(
          "Liquidity",
          value: current.liquidityUsd.map { DisplayFormat.compactCurrency(Decimal($0)) })
      }
    }
    .padding(.horizontal, 16).frame(height: 64)
  }

  private var price: String {
    if isLiveMarket {
      return livePrice.map {
        DisplayFormat.currency(Decimal($0), decimals: DisplayFormat.priceDecimals($0))
      } ?? "—"
    }
    return market.map { DisplayFormat.currency($0.price, decimals: 4) } ?? "—"
  }

  private var volume: String? {
    if isLiveMarket { return current.volume24h.map { DisplayFormat.compactCurrency(Decimal($0)) } }
    return market.map { DisplayFormat.compactCurrency($0.volume) }
  }
  private func formatPrice(_ value: Double) -> String {
    DisplayFormat.currency(Decimal(value), decimals: DisplayFormat.priceDecimals(value))
  }

  private func metric(_ label: String, value: String?) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(AppTypography.caption).foregroundStyle(.secondary)
      Text(value ?? "—").font(AppTypography.calloutMedium).monospacedDigit()
    }
    .frame(minWidth: 75, alignment: .leading)
    .help(
      value == nil
        ? "\(label) is loading or unavailable for this token."
        : label.contains("High") || label.contains("Low")
          ? "Rolling 24h range from completed minute candles.\(snapshot.map { " Window ends " + Date(timeIntervalSince1970: $0.rangeEnd).formatted(date: .omitted, time: .shortened) } ?? "")"
          : "\(label) for this token's selected market"
    )
    .accessibilityElement(children: .combine)
  }
}
