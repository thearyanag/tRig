import SwiftUI

struct WorkspaceSidebarView: View {
  let workspace: WorkspaceStore
  let selection: Binding<String?>
  let openSearch: () -> Void
  @State private var section = "Watchlist"

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      AssetIdentityView(asset: workspace.selectedAsset)
        .padding(.horizontal, 18).frame(height: 76)
      HStack(spacing: 4) {
        ForEach(["Context", "Watchlist"], id: \.self) { tab in
          Button {
            section = tab
          } label: {
            Text(tab).font(AppTypography.calloutMedium)
              .frame(maxWidth: .infinity).frame(height: 30)
              .contentShape(Rectangle())
          }
          .buttonStyle(
            TerminalControlStyle(
              fill: section == tab ? TerminalStyle.accent : TerminalStyle.field,
              border: section == tab ? TerminalStyle.accent : TerminalStyle.border)
          )
          .accessibilityAddTraits(section == tab ? .isSelected : [])
        }
      }
      .padding(.horizontal, 18).padding(.vertical, 12)
      VStack(alignment: .leading, spacing: 12) {
        Text("Your account").font(AppTypography.bodySemibold)
        Label("No wallet connected", systemImage: "wallet.bifold")
          .font(AppTypography.callout).foregroundStyle(.secondary)
        Text("Wallet connection is not available yet.")
          .font(AppTypography.caption).foregroundStyle(.secondary)
      }
      .padding(18)
      Divider().padding(.horizontal, 18)
      if section == "Watchlist" {
        HStack {
          Text("Watchlist").font(AppTypography.bodySemibold)
          Text("\(workspace.watchlist.count)").font(AppTypography.caption).foregroundStyle(
            .secondary)
          Spacer()
          Button(action: openSearch) { Image(systemName: "plus").frame(width: 28, height: 32) }
            .buttonStyle(.plain).foregroundStyle(.blue)
            .help("Find an asset to watch").accessibilityLabel("Find an asset to watch")
        }
        .padding(.horizontal, 18).padding(.top, 12)
        List(selection: selection) {
          ForEach(workspace.watchlist) { asset in
            HStack(spacing: 10) {
              AssetIconView(asset: asset, size: 28)
              Text(asset.symbol).font(AppTypography.calloutMedium)
              Text(asset.name).font(AppTypography.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, 6).tag(asset.id)
            .contextMenu { Button("Remove from watchlist") { workspace.toggleWatch(asset) } }
          }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .overlay {
          if workspace.watchlist.isEmpty {
            Text("Use ⌘K to find an asset").font(AppTypography.callout).foregroundStyle(.secondary)
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          Text("Selected asset").font(AppTypography.bodySemibold)
          contextRow("Network", workspace.selectedAsset.network)
          contextRow("Pair", "\(workspace.selectedAsset.symbol) / USD")
          contextRow("Market data", "GeckoTerminal")
          contextRow("Swap quotes", "Jupiter")
          contextRow("Execution", "Unavailable")
        }
        .padding(18)
        Spacer(minLength: 0)
      }
      Divider().padding(.horizontal, 18)
      Button {
        workspace.toggleWatch(workspace.selectedAsset)
      } label: {
        Label(
          workspace.isWatched(workspace.selectedAsset) ? "Watching asset" : "Watch asset",
          systemImage: workspace.isWatched(workspace.selectedAsset) ? "star.fill" : "star"
        )
        .font(AppTypography.calloutMedium).frame(maxWidth: .infinity).frame(height: 36)
      }
      .buttonStyle(TerminalControlStyle()).padding(18)
    }
    .frame(maxHeight: .infinity)
    .background(TerminalStyle.canvas)
  }

  private func contextRow(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(value)
    }.font(AppTypography.callout)
  }
}
