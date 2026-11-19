import SwiftUI

private enum TradingDockTab: String, CaseIterable, Identifiable {
  case positions = "Positions"
  case orders = "Orders"
  case activity = "Activity"

  var id: Self { self }
  var columns: [String] {
    switch self {
    case .positions: ["Asset", "Position", "Avg. entry", "Current price", "P&L", "Value"]
    case .orders: ["Asset", "Side", "Type", "Amount", "Price", "Status"]
    case .activity: ["Asset", "Action", "Amount", "Value", "Time", "Status"]
    }
  }
  var message: String {
    switch self {
    case .positions: "Your positions will appear here when wallet connection is available."
    case .orders: "Order execution is not available yet."
    case .activity: "Wallet activity will appear here when wallet connection is available."
    }
  }
}

struct TradingDockView: View {
  @State private var selected: TradingDockTab = .positions
  @SceneStorage("workspace.dockCollapsed") private var isCollapsed = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 20) {
        ForEach(TradingDockTab.allCases) { tab in
          Button {
            selected = tab
            isCollapsed = false
          } label: {
            Text(tab.rawValue)
              .font(AppTypography.calloutMedium)
              .foregroundStyle(selected == tab ? Color.primary : .secondary)
              .frame(minHeight: 38)
              .overlay(alignment: .bottom) {
                if selected == tab {
                  Capsule().fill(.tint).frame(height: 2)
                }
              }
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selected == tab ? .isSelected : [])
        }
        Spacer()
        Button {
          isCollapsed.toggle()
        } label: {
          Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
            .frame(width: 40, height: 38).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(isCollapsed ? "Expand trading activity" : "Collapse trading activity")
        .accessibilityLabel(isCollapsed ? "Expand trading activity" : "Collapse trading activity")
      }
      .padding(.leading, 16).padding(.trailing, 4)
      if !isCollapsed {
        Divider()
        HStack(spacing: 8) {
          ForEach(selected.columns, id: \.self) { column in
            Text(column).frame(
              maxWidth: .infinity, alignment: column == "Asset" ? .leading : .trailing)
          }
        }
        .font(AppTypography.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16).frame(height: 25)
        Divider().padding(.horizontal, 16)
        HStack(spacing: 10) {
          Image(systemName: "wallet.bifold").foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 3) {
            Text("No wallet connected").font(AppTypography.calloutMedium)
            Text(selected.message).font(AppTypography.caption).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
      }
    }
    .frame(height: isCollapsed ? 38 : 132)
    .background(TerminalStyle.canvas)
  }
}
