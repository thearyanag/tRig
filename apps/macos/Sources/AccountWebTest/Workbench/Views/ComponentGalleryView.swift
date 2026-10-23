import SwiftUI

private enum GalleryComponent: String, CaseIterable, Identifiable {
  case header = "Asset header"
  case ticket = "Trade ticket"
  case chart = "Chart"
  var id: Self { self }
}

private enum TicketExample: String, CaseIterable, Identifiable {
  case buy = "Buy"
  case sell = "Sell"
  case empty = "Empty"
  case invalid = "Invalid"
  case insufficient = "Over balance"
  var id: Self { self }
  var draft: TradeDraft {
    switch self {
    case .buy: TradeDraft()
    case .sell: TradeDraft(side: .sell, amountText: "100")
    case .empty: TradeDraft(amountText: "")
    case .invalid: TradeDraft(amountText: "abc")
    case .insufficient: TradeDraft(amountText: "1001")
    }
  }
}

struct ComponentGalleryView: View {
  @State private var component: GalleryComponent = .header
  @State private var example: TicketExample = .buy
  @State private var draft = TradeDraft()
  @State private var isWatched = true
  @State private var showMarket = true

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Component Gallery").font(.title.bold())
        Text("Interactive components · Local sample data")
          .font(.callout).foregroundStyle(.secondary)
      }
      Picker("Component", selection: $component) {
        ForEach(GalleryComponent.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      if component == .header {
        Toggle("Show sample market data", isOn: $showMarket)
        GroupBox {
          AssetHeaderView(
            asset: .backpack, market: showMarket ? .backpack : nil, isWatched: $isWatched
          )
          .padding(14)
        }
        Spacer()
      } else if component == .chart {
        ChartPanelView()
          .frame(minHeight: 440)
      } else {
        Picker("Example state", selection: $example) {
          ForEach(TicketExample.allCases) { Text($0.rawValue).tag($0) }
        }
        .onChange(of: example) { _, value in draft = value.draft }
        HStack {
          Spacer(minLength: 0)
          TradeTicketView(asset: .backpack, draft: $draft)
            .frame(width: 340)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
          Spacer(minLength: 0)
        }
      }
    }
    .padding(24).frame(minWidth: 640, minHeight: 680)
  }
}

#Preview {
  ComponentGalleryView().frame(width: 760, height: 860)
}
