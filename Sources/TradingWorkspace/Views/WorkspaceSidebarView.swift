import SwiftUI

struct WorkspaceSidebarView: View {
  let workspace: WorkspaceStore
  let selection: Binding<String?>
  @Binding var showContext: Bool
  @Binding var showSupport: Bool
  let telegram: TelegramSession
  let openSearch: () -> Void
  @Environment(WalletStore.self) private var wallet
  private var section: String { showContext ? "Context" : "Watchlist" }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      AssetIdentityView(asset: workspace.selectedAsset)
        .padding(.horizontal, 18).frame(height: 76)
      HStack(spacing: 4) {
        ForEach(["Context", "Watchlist"], id: \.self) { tab in
          Button {
            showContext = tab == "Context"
          } label: {
            Text(tab).font(AppTypography.calloutMedium)
              .frame(maxWidth: .infinity).frame(height: 30)
              .contentShape(Rectangle())
          }
          .buttonStyle(
            TerminalControlStyle(
              fill: section == tab ? TerminalStyle.accent : TerminalStyle.field,
              border: section == tab ? TerminalStyle.accent : TerminalStyle.border,
              glass: .init(tint: section == tab ? TerminalStyle.accent : nil))
          )
          .accessibilityAddTraits(section == tab ? .isSelected : [])
        }
      }
      .terminalGlassGroup()
      .terminalControlTrack(cornerRadius: 10)
      .padding(.horizontal, 18).padding(.vertical, 12)
      if !showContext {
        VStack(alignment: .leading, spacing: 12) {
          Text("Your account").font(AppTypography.bodySemibold)
          Label(wallet.wallets.isEmpty ? "No trading wallet" : wallet.isUnlocked ? "Wallet unlocked" : "Wallet locked",
            systemImage: "wallet.bifold")
            .font(AppTypography.callout).foregroundStyle(.secondary)
          Text(wallet.wallets.isEmpty ? "Open Wallet to create or import an account." :
            "Manage your trading accounts in Wallet.")
            .font(AppTypography.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        Divider().padding(.horizontal, 18)
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
          ForEach(workspace.watchlist, id: \.identity) { asset in
            HStack(spacing: 10) {
              AssetIconView(asset: asset, size: 28)
              VStack(alignment: .leading, spacing: 3) {
                HStack {
                  Text(asset.symbol).font(AppTypography.calloutMedium)
                  Text(asset.name).font(AppTypography.callout).foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Text(asset.network).font(AppTypography.caption).foregroundStyle(.secondary)
              }
            }
            .padding(.vertical, 6).tag(asset.identity)
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
        TelegramDiscussionView(asset: workspace.selectedAsset, session: telegram)
          .id(workspace.selectedAsset.identity + telegram.epoch.uuidString)
      }
      Divider().padding(.horizontal, 18)
      VStack(spacing: 8) {
        Button {
          showSupport.toggle()
        } label: {
          Label("Support", systemImage: "bubble.left")
            .font(AppTypography.calloutMedium)
            .frame(maxWidth: .infinity).frame(height: 36)
        }
        .buttonStyle(TerminalControlStyle(
          fill: showSupport ? TerminalStyle.accent : TerminalStyle.field,
          glass: .init(tint: showSupport ? TerminalStyle.accent : nil, cornerRadius: 16)))
        .accessibilityAddTraits(showSupport ? .isSelected : [])
        .help(showSupport ? "Close support panel" : "Open tRig Support")
        .anchorPreference(key: SupportButtonBounds.self, value: .bounds) { $0 }
        Button {
          workspace.toggleWatch(workspace.selectedAsset)
        } label: {
          Label(
            workspace.isWatched(workspace.selectedAsset) ? "Watching asset" : "Watch asset",
            systemImage: workspace.isWatched(workspace.selectedAsset) ? "star.fill" : "star"
          )
          .font(AppTypography.calloutMedium).frame(maxWidth: .infinity).frame(height: 36)
        }
        .buttonStyle(TerminalControlStyle(glass: .init(cornerRadius: 16)))
      }
      .padding(18)
    }
    .frame(maxHeight: .infinity)
    .background { WorkspaceChrome(region: .sidebar) }
  }

}

enum SupportButtonBounds: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? { nil }

  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = nextValue() ?? value
  }
}
