import SwiftUI

struct MarketStatsView: View {
  let asset: Asset
  var market: SampleMarket?
  var livePrice: Double?
  var isLiveMarket: Bool

  var body: some View {
    HStack(spacing: 20) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(price).font(AppTypography.font(size: 28, weight: .semibold)).monospacedDigit()
          .lineLimit(1).minimumScaleFactor(0.7)
        if !isLiveMarket, let market {
          Text(
            "\(market.changePercent >= 0 ? "+" : "")\(DisplayFormat.number(market.changePercent, decimals: 2))%"
          )
          .foregroundStyle(market.changePercent >= 0 ? Color.green : .red)
          .font(AppTypography.calloutMedium)
        }
      }
      Spacer(minLength: 0)
      metric("24h High", value: nil)
      Divider().frame(height: 30)
      metric("24h Low", value: nil)
      Divider().frame(height: 30)
      metric(isLiveMarket ? "24h Volume" : "24h Volume (sample)", value: volume)
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
    if isLiveMarket { return asset.volume24h.map { DisplayFormat.compactCurrency(Decimal($0)) } }
    return market.map { DisplayFormat.compactCurrency($0.volume) }
  }

  private func metric(_ label: String, value: String?) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(AppTypography.caption).foregroundStyle(.secondary)
      Text(value ?? "—").font(AppTypography.calloutMedium).monospacedDigit()
    }
    .frame(minWidth: 75, alignment: .leading)
    .help(
      value == nil
        ? "\(label) is not available from the current data integration."
        : "\(label) for the chart's market source"
    )
    .accessibilityElement(children: .combine)
  }
}
