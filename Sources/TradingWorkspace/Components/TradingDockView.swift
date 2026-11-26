import SwiftUI

private enum TradingOrderProvider: String, CaseIterable, Identifiable {
  case jupiter = "Jupiter"
  case flash = "Flash"
  var id: Self { self }
}

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
    case .positions: "Connected portfolio holdings will appear here."
    case .orders: "Add a tRig wallet to see its orders."
    case .activity: "Wallet transactions will appear here."
    }
  }
}

struct TradingDockView: View {
  var portfolio: PortfolioStore? = nil
  var wallet: WalletStore? = nil
  var selectedMint = ""
  var selectedChain = "solana"
  var openHolding: (PortfolioHolding) -> Void = { _ in }
  @State private var selected: TradingDockTab = .positions
  @State private var selectedOrderProvider: TradingOrderProvider?
  @SceneStorage("workspace.dockCollapsed") private var isCollapsed = false
  private var orderProvider: TradingOrderProvider {
    selectedOrderProvider ?? (selectedChain == "solana" ? .jupiter : .flash)
  }

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
        if selected == .positions, let portfolio {
          Text(
            "All accounts · \(portfolio.market?.holdings.count ?? 0) assets\(portfolio.marketIsSaved ? " · Saved data" : "")"
          )
          .font(AppTypography.caption).foregroundStyle(.secondary)
          .help(
            "Balances and marks come from the saved account snapshot, independently of the live chart and swap quote."
          )
        }
        Spacer()
        if selected == .orders {
          Picker("Order provider", selection: Binding(
            get: { orderProvider }, set: { selectedOrderProvider = $0 })
          ) {
            ForEach(TradingOrderProvider.allCases) { Text($0.rawValue).tag($0) }
          }
          .labelsHidden().pickerStyle(.segmented).frame(width: 136)
        }
        if selected == .activity, let wallet,
          !wallet.activity.entries.isEmpty || !wallet.trades.entries.isEmpty {
          Button {
            Task { await wallet.refreshActivity() }
          } label: {
            Image(systemName: "arrow.clockwise")
              .frame(width: 30, height: 30).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Refresh wallet activity")
          .disabled(wallet.activity.refreshing || wallet.trades.refreshing)
        }
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
        if selected == .positions, let portfolio {
          MarketPositionsView(
            snapshot: portfolio.market, selectedChain: selectedChain, selectedMint: selectedMint,
            loading: portfolio.isRefreshing || portfolio.isRestoringConnections || portfolio.isWalletRefreshing,
            open: openHolding)
        } else if selected == .activity, let wallet {
          WalletMarketActivityView(wallet: wallet)
        } else if selected == .orders, let wallet {
          if orderProvider == .jupiter {
            JupiterTriggerOrdersView(walletStore: wallet)
          } else {
            FlashOrdersView(walletStore: wallet)
          }
        } else {
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
            Text(selected.message).font(AppTypography.callout).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.horizontal, 16)
        }
      }
    }
    .frame(height: isCollapsed ? 38 : 180)
    .background(TerminalStyle.canvas)
  }
}
