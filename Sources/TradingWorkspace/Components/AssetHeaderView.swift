import SwiftUI

struct AssetHeaderView: View {
  let asset: Asset
  var market: SampleMarket? = nil
  var livePrice: Double? = nil
  var isLiveMarket = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        AssetIdentityView(asset: asset)
        Spacer(minLength: 8)
        Text(isLiveMarket ? "GeckoTerminal" : "Sample data")
          .font(AppTypography.caption).foregroundStyle(.secondary)
        Link(destination: URL(string: "https://solscan.io/token/\(asset.id)")!) {
          Label("Explorer", systemImage: "arrow.up.right")
            .font(AppTypography.callout)
        }
        .buttonStyle(.plain).foregroundStyle(.blue)
      }
      .padding(.horizontal, 16).frame(height: 76)
      Divider()
      MarketStatsView(
        asset: asset, market: market, livePrice: livePrice, isLiveMarket: isLiveMarket)
    }
  }
}

#Preview {
  AssetHeaderView(asset: .backpack, market: .backpack)
    .frame(width: 1000).preferredColorScheme(.dark)
}
