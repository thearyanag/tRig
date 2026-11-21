import SwiftUI

struct AssetHeaderView: View {
  let asset: Asset
  var market: SampleMarket? = nil
  var livePrice: Double? = nil
  var isLiveMarket = false
  var snapshot: MarketSnapshot? = nil
  var tradesVisible = false
  var toggleTrades: (() -> Void)? = nil
  var marketError: String? = nil

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        AssetIdentityView(asset: asset)
        Spacer(minLength: 8)
        if let snapshot {
          if snapshot.rangeLoading == true {
            ProgressView().controlSize(.mini).help("Loading the rolling 24h range…")
          }
          Text(
            "Updated \(Date(timeIntervalSince1970: snapshot.fetchedAt).formatted(date: .omitted, time: .shortened))"
          )
          .font(AppTypography.caption).foregroundStyle(.secondary)
        }
        if let marketError {
          Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(marketError)
        }
        if !isLiveMarket {
          Text("Sample data").font(AppTypography.caption).foregroundStyle(.secondary)
        }
        ForEach(snapshot?.links ?? []) { link in
          if let destination = link.destination {
            Link(destination: destination) {
              Label(link.title, systemImage: "arrow.up.right").font(AppTypography.caption)
            }
            .buttonStyle(.plain).foregroundStyle(.blue)
          }
        }
        if let destination = asset.tokenExplorer {
          Link(destination: destination) {
            Label("Explorer", systemImage: "arrow.up.right")
              .font(AppTypography.callout)
          }
          .buttonStyle(.plain).foregroundStyle(.blue)
        }
        if let toggleTrades {
          Button(action: toggleTrades) {
            Image(systemName: "list.bullet.rectangle").frame(width: 32, height: 32)
          }.buttonStyle(.plain).foregroundStyle(
            tradesVisible ? TerminalStyle.accent : Color.secondary
          )
          .accessibilityLabel(tradesVisible ? "Hide recent trades" : "Show recent trades")
        }
      }
      .padding(.horizontal, 16).frame(height: 76)
      Divider()
      MarketStatsView(
        asset: asset, market: market, livePrice: livePrice, isLiveMarket: isLiveMarket,
        snapshot: snapshot)
    }
  }
}

#Preview {
  AssetHeaderView(asset: .backpack, market: .backpack)
    .frame(width: 1000).preferredColorScheme(.dark)
}
