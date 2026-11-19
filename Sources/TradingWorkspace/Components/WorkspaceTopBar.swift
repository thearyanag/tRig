import SwiftUI

struct WorkspaceTopBar: View {
  @Binding var showSidebar: Bool
  let openSearch: () -> Void

  var body: some View {
    HStack(spacing: 18) {
      Text("Workspace").font(AppTypography.bodySemibold)
      Text("Markets").font(AppTypography.callout).foregroundStyle(.primary)
      Text("Portfolio").font(AppTypography.callout).foregroundStyle(.tertiary)
        .help("Portfolio will be available with wallet connection")
      Spacer(minLength: 8)
      Button(action: openSearch) {
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass")
          Text("Search tokens or paste a CA…").foregroundStyle(.secondary)
          Spacer(minLength: 16)
          Text("⌘ K").foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(TerminalStyle.panel, in: RoundedRectangle(cornerRadius: 4))
        }
        .font(AppTypography.callout)
        .padding(.horizontal, 12).frame(width: 320, height: 34)
        .background(
          TerminalStyle.field, in: RoundedRectangle(cornerRadius: TerminalStyle.controlRadius)
        )
        .overlay(
          RoundedRectangle(cornerRadius: TerminalStyle.controlRadius).strokeBorder(
            TerminalStyle.border)
        )
        .frame(minHeight: 40)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain).accessibilityLabel("Search assets or paste a contract address")
      Spacer(minLength: 8)
      Button {
        showSidebar.toggle()
      } label: {
        Image(systemName: "sidebar.left").frame(width: 32, height: 40)
      }
      .buttonStyle(.plain).help(showSidebar ? "Hide left pane" : "Show left pane")
      .accessibilityLabel(showSidebar ? "Hide left pane" : "Show left pane")
      Divider().frame(height: 22)
      Text("Quote only").font(AppTypography.caption).foregroundStyle(.secondary)
      SettingsLink {
        Image(systemName: "gearshape").frame(width: 32, height: 40)
      }
      .buttonStyle(.plain).help("Settings (⌘,)")
      .accessibilityLabel("Settings")
    }
    .padding(.leading, 96).padding(.trailing, 14)
    .frame(height: 54)
    .background(TerminalStyle.panel)
    .background(WindowDragRegion())
    .overlay(alignment: .leading) { WindowControlsView().frame(width: 86, height: 54) }
    .overlay(alignment: .bottom) { Divider() }
  }
}
