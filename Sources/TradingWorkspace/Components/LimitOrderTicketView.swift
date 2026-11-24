import SwiftUI

struct LimitOrderTicketView: View {
  let asset: Asset
  @Binding var trade: TradeDraft
  @Binding var limit: LimitOrderDraft
  let referencePrice: Double?
  @State private var store = ExecutionQuoteStore()
  @State private var showDetails = false
  @FocusState private var amountFocused: Bool
  private var request: ExecutionQuoteRequest { limit.request(asset: asset, trade: trade) }
  private var tint: Color { trade.side == .buy ? TerminalStyle.buy : TerminalStyle.sell }
  private var priceBinding: Binding<String> {
    Binding(get: { limit.priceText }, set: { limit.setPrice($0) })
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { clock in
      let quote = store.visible(for: request)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          SwapTokenAmountView(
            title: trade.side == .buy ? "Spend" : "Sell quantity", asset: asset,
            usesUSDC: trade.side == .buy, amount: $trade.amountText, editable: true,
            fiatValue: asset.settlement?.symbol == "USDC"
              ? SwapTicketDisplay.fiat(
                trade.amountText, isUSDC: trade.side == .buy, referencePrice: referencePrice) : nil,
            amountFocused: $amountFocused,
            selectToken: { trade.selectQuoteSide($0 ? .buy : .sell) },
            submit: { store.load(request) })
          targetPrice
          VStack(spacing: 8) {
            row("At limit · before fees", localReceive)
            if let quote {
              Divider()
              row(
                "Quoted receive",
                "\(PortfolioFormat.quantity(quote.receiveAmount)) \(receiveSymbol)")
              row(
                "Minimum receive",
                quote.minimumReceive.map { "\(PortfolioFormat.quantity($0)) \(receiveSymbol)" }
                  ?? "Not supplied")
              Text(
                quote.isFresh(at: clock.date)
                  ? "Quote updated \(max(0, Int(clock.date.timeIntervalSince1970 - quote.fetchedAt)))s ago"
                  : "Quote is stale · refresh"
              )
              .font(AppTypography.caption)
              .foregroundStyle(quote.isFresh(at: clock.date) ? Color.secondary : .orange)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(10).background(TerminalStyle.field.opacity(0.5))
          .overlay { Rectangle().strokeBorder(TerminalStyle.border) }
          DisclosureGroup("Quote details", isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 10) {
              slippage
              if let quote {
                row("Route", quote.providerName)
                ForEach(Array(quote.fees.enumerated()), id: \.offset) { _, fee in
                  row(
                    fee.kind,
                    fee.amountUsd.map { PortfolioFormat.currency($0) }
                      ?? fee.rateBps.map {
                        DisplayFormat.number(Decimal($0) / 100, decimals: 2) + "%"
                      }
                      ?? "Not supplied")
                }
                ForEach(quote.warnings, id: \.self) { warning in
                  Text(warning).font(AppTypography.caption).foregroundStyle(.secondary)
                }
              } else {
                Text("A supported route is selected automatically when you preview.")
                  .font(AppTypography.caption).foregroundStyle(.secondary)
              }
            }.padding(.top, 10)
          }
          .font(AppTypography.caption)
          if let error = store.error {
            Text(error).font(AppTypography.caption).foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
        }.padding(12)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          Button {
            amountFocused = false
            store.load(request)
          } label: {
            HStack(spacing: 6) {
              if store.isLoading { ProgressView().controlSize(.mini) }
              Text(
                store.isLoading
                  ? "Getting quote…" : "Preview limit \(trade.side.rawValue.lowercased())")
            }
            .font(AppTypography.bodySemibold).frame(maxWidth: .infinity).frame(height: 40)
          }
          .buttonStyle(TerminalControlStyle.primary)
          .disabled(!request.isValid || store.isLoading)
          Text("Quote preview only. No order will be placed.")
            .font(AppTypography.caption).foregroundStyle(.secondary)
        }.padding(12).background(TerminalStyle.quotePanel)
          .overlay(alignment: .top) { Divider() }
      }
    }
    .font(AppTypography.body)
    .onChange(of: request) { _, value in store.requestDidChange(value) }
    .onDisappear { store.clear() }
  }

  private var targetPrice: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Limit price").font(AppTypography.calloutMedium)
        Spacer()
        Text("USD / \(asset.symbol)").foregroundStyle(.secondary).font(AppTypography.caption)
      }
      HStack(spacing: 5) {
        Text("$").foregroundStyle(.secondary)
        TextField("Enter price", text: priceBinding)
          .textFieldStyle(.plain).font(AppTypography.font(size: 22, weight: .medium))
          .monospacedDigit().accessibilityLabel("Limit price in USD for \(asset.symbol)")
      }.padding(10).background(TerminalStyle.field)
        .overlay { Rectangle().strokeBorder(TerminalStyle.border) }
      HStack(alignment: .firstTextBaseline) {
        Text(
          referencePrice.map { "Current $\(LimitOrderDraft.formatted($0))" }
            ?? "Current price unavailable")
        Spacer(minLength: 3)
        if let price = limit.price, let referencePrice, referencePrice > 0 {
          let difference = (price / referencePrice - 1) * 100
          Text(
            "\(DisplayFormat.number(Decimal(abs(difference)), decimals: 1))% \(difference < 0 ? "below" : "above")"
          )
        }
      }.font(AppTypography.caption).foregroundStyle(.secondary).monospacedDigit()
      HStack(spacing: 4) {
        priceShortcut("Market", percent: 0)
        ForEach([5, 10, 25], id: \.self) { value in
          let percent = trade.side == .buy ? -value : value
          priceShortcut("\(percent > 0 ? "+" : "−")\(value)%", percent: percent)
        }
      }
      if let price = limit.price, let referencePrice,
        (trade.side == .buy && price >= referencePrice)
          || (trade.side == .sell && price <= referencePrice)
      {
        Text("This limit crosses the current market and could fill immediately when placed.")
          .font(AppTypography.caption).foregroundStyle(.orange)
      }
      Label(
        "Draft \(trade.side.rawValue.lowercased()) limit · \(asset.hasChart ? "drag the chart line" : "enter a target price")",
        systemImage: "line.diagonal"
      )
      .font(AppTypography.caption).foregroundStyle(tint).fixedSize(
        horizontal: false, vertical: true)
      if limit.priceText.isEmpty {
        Text("Enter a target price or use a shortcut to add the draft line.")
          .font(AppTypography.caption).foregroundStyle(.secondary)
      } else if limit.price == nil {
        Text("Enter a positive price using digits and a decimal point.")
          .font(AppTypography.caption).foregroundStyle(.orange)
      }
    }
  }

  private var receiveSymbol: String {
    trade.side == .buy ? asset.symbol : asset.settlement?.symbol ?? "Quote token"
  }
  private var localReceive: String {
    guard asset.settlement?.symbol == "USDC", limit.price != nil,
      let price = Decimal(string: limit.priceText), price > 0,
      QuoteAmount.isPositive(request.amount), let amount = Decimal(string: request.amount)
    else { return "—" }
    let value = trade.side == .buy ? amount / price : amount * price
    guard !value.isNaN else { return "—" }
    return DisplayFormat.number(value, decimals: 6) + " " + receiveSymbol
  }

  private func priceShortcut(_ title: String, percent: Int) -> some View {
    Button {
      limit.preset(percent, reference: referencePrice)
    } label: {
      Text(title).font(AppTypography.caption).frame(maxWidth: .infinity).frame(height: 27)
    }
    .buttonStyle(TerminalControlStyle(fill: TerminalStyle.field))
    .disabled(referencePrice == nil)
    .accessibilityLabel(
      percent == 0
        ? "Set limit to current market price"
        : "Set limit \(abs(percent)) percent \(percent < 0 ? "below" : "above") current price")
  }

  private var slippage: some View {
    HStack(spacing: 4) {
      Text("Slippage").foregroundStyle(.secondary)
      Spacer()
      ForEach(SlippagePreset.allCases) { preset in
        Button {
          trade.slippage = preset
        } label: {
          Text(preset.rawValue).frame(width: 42, height: 26)
        }
        .buttonStyle(
          TerminalControlStyle(
            fill: trade.slippage == preset
              ? TerminalStyle.accent.opacity(0.15) : TerminalStyle.field,
            border: trade.slippage == preset ? TerminalStyle.accent : TerminalStyle.border)
        )
        .accessibilityLabel("\(preset.rawValue) limit slippage")
      }
    }
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title).foregroundStyle(.secondary)
      Spacer(minLength: 2)
      Text(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
    }.font(AppTypography.caption)
  }
}
