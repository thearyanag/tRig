import SwiftUI

struct PortfolioSidebarView: View {
  @Binding var scope: PortfolioScope
  let workspace: WorkspaceStore
  let openMarket: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Portfolios").font(AppTypography.font(size: 18, weight: .semibold))
        .padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 16)
      VStack(spacing: 4) {
        ForEach(PortfolioScope.allCases) { item in
          Button {
            scope = item
          } label: {
            HStack(spacing: 12) {
              Image(systemName: item == .wallet ? "wallet.bifold" : "square.3.layers.3d")
                .frame(width: 18)
              Text(item.name).font(AppTypography.font(size: 15, weight: .medium))
              Spacer()
            }
            .padding(.horizontal, 12).frame(height: 38)
          }
          .buttonStyle(
            TerminalControlStyle(
              fill: scope == item ? TerminalStyle.accent : .clear,
              border: scope == item ? TerminalStyle.accent : .clear,
              glass: scope == item ? .init(tint: TerminalStyle.accent) : nil)
          )
          .accessibilityLabel("Show \(item.name) portfolio")
          .accessibilityAddTraits(scope == item ? .isSelected : [])
        }
      }.padding(.horizontal, 14)
      Divider().padding(.horizontal, 18).padding(.vertical, 18)
      Text("Watchlist").font(AppTypography.font(size: 16, weight: .semibold)).padding(
        .horizontal, 22
      ).padding(
        .bottom, 10)
      ScrollView {
        VStack(spacing: 2) {
          ForEach(workspace.watchlist, id: \.identity) { asset in
            Button {
              workspace.open(asset)
              openMarket()
            } label: {
              HStack(spacing: 12) {
                AssetIconView(asset: asset, size: 24)
                Text(asset.symbol).font(AppTypography.font(size: 14, weight: .medium)).lineLimit(1)
                Text(asset.network).font(AppTypography.caption).foregroundStyle(.secondary)
                Spacer()
              }
              .padding(.horizontal, 10).frame(height: 38).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Open \(asset.symbol) in Markets")
          }
        }.padding(.horizontal, 14)
      }
      Spacer(minLength: 0)
    }
    .frame(width: 248).frame(maxHeight: .infinity)
    .background { WorkspaceChrome(region: .sidebar) }
  }
}
