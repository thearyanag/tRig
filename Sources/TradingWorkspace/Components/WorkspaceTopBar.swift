import SwiftUI

struct WorkspaceTopBar: View {
  @Binding var showSidebar: Bool
  @Binding var section: WorkspaceSection
  let marketNetwork: String
  let openSearch: () -> Void
  @Environment(\.openWorkspaceSettings) private var openSettings

  private var usesGlass: Bool {
    if #available(macOS 26, *) { return true }
    return false
  }

  var body: some View {
    HStack(spacing: 18) {
      HStack(spacing: usesGlass ? 24 : 10) {
        Button {
          showSidebar.toggle()
        } label: {
          Image(systemName: "sidebar.left")
            .frame(width: 30, height: 30).terminalGlass(.init(cornerRadius: 15))
            .frame(width: 32, height: 40)
        }
        .buttonStyle(.plain).help(showSidebar ? "Hide left pane" : "Show left pane")
        .accessibilityLabel(showSidebar ? "Hide left pane" : "Show left pane")
        Text("Workspace").font(AppTypography.bodySemibold)
      }
      .padding(.trailing, usesGlass ? 34 : 0)
      .fixedSize()
      HStack(spacing: 4) {
        ForEach(WorkspaceSection.allCases) { value in
          Button {
            section = value
          } label: {
            Text(value.rawValue).font(AppTypography.calloutMedium).padding(.horizontal, 14)
              .frame(minWidth: usesGlass ? 100 : nil).frame(height: 34)
          }
          .buttonStyle(
            TerminalControlStyle(
              fill: section == value ? TerminalStyle.accent : .clear,
              border: section == value ? TerminalStyle.accent : .clear,
              glass: section == value ? .init(tint: TerminalStyle.accent, cornerRadius: 16) : nil)
          )
          .accessibilityAddTraits(section == value ? .isSelected : [])
        }
      }
      .terminalControlTrack(cornerRadius: 19)
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
        .padding(.horizontal, 12).frame(width: usesGlass ? 400 : 320, height: 34)
      }
      .buttonStyle(TerminalControlStyle(glass: .init(cornerRadius: 17)))
      .accessibilityLabel("Search assets or paste a contract address")
      Spacer(minLength: 8)
      WalletControl(marketNetwork: marketNetwork)
      Button { openSettings(nil) } label: {
        Image(systemName: "gearshape")
          .frame(width: 30, height: 30).terminalGlass(.init(cornerRadius: 15))
          .frame(width: 32, height: 40)
      }
      .buttonStyle(.plain).help("Settings (⌘,)")
      .accessibilityLabel("Settings")
    }
    .padding(.leading, usesGlass ? 118 : 96).padding(.trailing, 14)
    .frame(height: 54)
    .terminalGlassGroup()
    .background { WorkspaceChrome(region: .toolbar) }
    .background(WindowDragRegion())
    .overlay(alignment: .leading) {
      WindowControlsView().frame(width: usesGlass ? 106 : 86, height: 54)
    }
    .overlay(alignment: .bottom) { Divider() }
  }
}
