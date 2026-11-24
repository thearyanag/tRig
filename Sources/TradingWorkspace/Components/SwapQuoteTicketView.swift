import SwiftUI

struct SwapQuoteTicketView: View {
  let asset: Asset
  @Binding var draft: TradeDraft
  @Binding var limitDraft: LimitOrderDraft
  @Binding var exitDraft: ExitOrderDraft
  var referencePrice: Double? = nil
  @State private var store = SwapQuoteStore()
  @State private var review: SwapQuote?
  @State private var routeMode: ExecutionOrderType?
  @FocusState private var amountFocused: Bool
  private var input: SwapQuoteInput { SwapQuoteInput(asset: asset, draft: draft) }

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 8) {
        sideTabs
        orderMode
      }.terminalGlassGroup().padding(12)
      if exitDraft.isEnabled {
        ExitOrderTicketView(
          asset: asset, exits: $exitDraft, slippage: $draft.slippage,
          referencePrice: referencePrice ?? asset.priceUsd)
      } else if limitDraft.isEnabled {
        LimitOrderTicketView(
          asset: asset, trade: $draft, limit: $limitDraft,
          referencePrice: referencePrice ?? asset.priceUsd)
      } else {
        if asset.isSolana { marketTicket } else { EVMMarketQuoteView(asset: asset, trade: $draft) }
      }
    }
    .background(TerminalStyle.quotePanel)
    .onChange(of: draft.side) { _, side in
      if limitDraft.isEnabled {
        limitDraft.setPrice("")
        limitDraft.preset(side == .buy ? -5 : 5, reference: referencePrice ?? asset.priceUsd)
      }
    }
  }

  private var marketTicket: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let quote = store.visible(for: input)
      let fresh = quote?.isFresh(at: context.date) == true
      ScrollView {
        VStack(spacing: 8) {
          SwapTokenAmountView(
            title: "From", asset: asset, usesUSDC: draft.side == .buy,
            amount: $draft.amountText, editable: true,
            fiatValue: SwapTicketDisplay.fiat(
              draft.amountText, isUSDC: draft.side == .buy,
              referencePrice: referencePrice ?? asset.priceUsd),
            amountFocused: $amountFocused,
            selectToken: { changeSide($0 ? .buy : .sell) },
            submit: { store.load(input) })
          Button {
            draft.reverseQuote(asset: asset, quote: quote, at: context.date)
            amountFocused = true
          } label: {
            Image(systemName: "arrow.up.arrow.down")
              .font(.system(size: 11, weight: .medium)).frame(width: 36, height: 32)
          }
          .buttonStyle(TerminalControlStyle(fill: TerminalStyle.panel))
          .help("Reverse the swap direction")
          .accessibilityLabel("Reverse swap direction")
          .disabled(asset.id == SwapQuoteInput.usdc)
          SwapTokenAmountView(
            title: "To (estimated)", asset: asset, usesUSDC: draft.side == .sell,
            amount: .constant(quote?.receiveAmount ?? ""), editable: false,
            fiatValue: SwapTicketDisplay.fiat(
              quote?.receiveAmount, isUSDC: draft.side == .sell,
              referencePrice: referencePrice ?? asset.priceUsd),
            amountFocused: $amountFocused,
            selectToken: { changeSide($0 ? .sell : .buy) })
          slippage
          Button("Cross-chain & advanced quotes…") { routeMode = .market }
            .buttonStyle(.plain).font(AppTypography.caption).foregroundStyle(.blue)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
          if asset.id == SwapQuoteInput.usdc {
            Text("Choose another asset to quote against USDC.")
              .font(AppTypography.callout).foregroundStyle(.secondary)
          }
          if store.isLoading {
            HStack(spacing: 8) {
              ProgressView().controlSize(.mini)
              Text("Finding a route…").foregroundStyle(.secondary)
              Spacer()
            }.font(AppTypography.caption)
          }
          if let error = store.error {
            Text(error).font(AppTypography.callout).foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true).frame(
                maxWidth: .infinity, alignment: .leading)
          }
          SwapQuoteSummaryView(quote: quote)
          if let quote {
            HStack {
              Text(
                fresh
                  ? "Quoted \(max(0, Int(context.date.timeIntervalSince1970 - quote.fetchedAt)))s ago"
                  : "Quote is stale"
              )
              .foregroundStyle(fresh ? Color.secondary : .orange)
              Spacer()
              Button {
                store.load(input)
              } label: {
                Image(systemName: "arrow.clockwise").frame(width: 30, height: 28)
              }
              .buttonStyle(TerminalControlStyle(fill: .clear))
              .disabled(store.isLoading).help("Refresh quote").accessibilityLabel("Refresh quote")
            }.font(AppTypography.caption)
          }
        }.padding(12)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          Button {
            amountFocused = false
            if let quote, fresh { review = quote } else { store.load(input) }
          } label: {
            Text(fresh ? "Review quote" : (store.isLoading ? "Getting quote…" : "Get quote"))
              .font(AppTypography.bodySemibold).frame(maxWidth: .infinity).frame(height: 40)
          }
          .buttonStyle(TerminalControlStyle.primary)
          .disabled(!input.isValid || store.isLoading)
          Text("Jupiter quotes exclude wallet costs. No order is placed.")
            .font(AppTypography.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).background(TerminalStyle.quotePanel)
        .overlay(alignment: .top) { Divider() }
      }
    }
    .font(AppTypography.body).background(TerminalStyle.quotePanel)
    .onChange(of: input) { _, value in
      store.requestDidChange(value)
      review = nil
    }
    .onDisappear { store.clear() }
    .sheet(item: $review) { SwapQuoteReviewView(quote: $0) }
    .sheet(item: $routeMode) {
      ExecutionQuoteView(
        asset: asset, initialOrderType: $0, initialSide: draft.side, initialAmount: draft.amountText
      )
    }
  }

  private var sideTabs: some View {
    HStack(spacing: 4) {
      ForEach(TradeSide.allCases) { side in
        let selected = draft.side == side
        let tint = side == .buy ? TerminalStyle.buy : TerminalStyle.sell
        Button {
          changeSide(side)
        } label: {
          Text(side.rawValue).font(AppTypography.bodySemibold)
            .frame(maxWidth: .infinity).frame(height: 36)
        }
        .buttonStyle(
          TerminalControlStyle(
            fill: selected ? tint : TerminalStyle.field,
            foreground: selected ? (side == .buy ? TerminalStyle.field : .white) : .secondary,
            border: selected ? tint : TerminalStyle.border,
            glass: .init(
              tint: selected ? tint : nil,
              inactiveForeground: selected && side == .buy ? .primary : nil))
        )
        .accessibilityLabel("\(side.rawValue) \(asset.symbol)")
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .terminalControlTrack(cornerRadius: 10)
  }

  private var orderMode: some View {
    HStack(spacing: 4) {
      ForEach(["Market", "Limit", "TP/SL"], id: \.self) { mode in
        let selected =
          mode == "TP/SL"
          ? exitDraft.isEnabled
          : !exitDraft.isEnabled && (limitDraft.isEnabled == (mode == "Limit"))
        Button {
          store.clear()
          if mode == "TP/SL" { draft.selectQuoteSide(.sell) }
          limitDraft.setEnabled(
            mode == "Limit", reference: referencePrice ?? asset.priceUsd, side: draft.side)
          exitDraft.setEnabled(mode == "TP/SL", reference: referencePrice ?? asset.priceUsd)
        } label: {
          Text(mode).font(AppTypography.calloutMedium)
            .frame(maxWidth: .infinity).frame(height: 28)
        }
        .buttonStyle(
          TerminalControlStyle(
            fill: selected ? TerminalStyle.panel : TerminalStyle.field,
            foreground: selected ? .primary : .secondary,
            border: selected ? .white.opacity(0.2) : TerminalStyle.border,
            glass: .init(tint: selected ? .white.opacity(0.13) : nil, cornerRadius: 8))
        )
        .accessibilityLabel(mode == "TP/SL" ? "Take profit and stop loss" : "\(mode) order")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(mode != "Market" && (!asset.supportsConditions || asset.settlement == nil))
        .help(
          mode != "Market" && !asset.supportsConditions
            ? "Conditional quotes are unavailable on this network." : "")
      }
    }
    .terminalControlTrack(cornerRadius: 8)
  }

  private var slippage: some View {
    HStack(spacing: 4) {
      Text("Slippage").font(AppTypography.caption).foregroundStyle(.secondary)
      Spacer(minLength: 8)
      ForEach(SlippagePreset.allCases) { preset in
        Button {
          draft.slippage = preset
        } label: {
          Text(preset.rawValue).font(AppTypography.caption).frame(width: 42, height: 28)
        }
        .buttonStyle(
          TerminalControlStyle(
            fill: draft.slippage == preset ? TerminalStyle.accent.opacity(0.15) : .clear,
            foreground: draft.slippage == preset ? .primary : .secondary,
            border: draft.slippage == preset
              ? TerminalStyle.accent.opacity(0.5) : TerminalStyle.border,
            glass: .init(tint: draft.slippage == preset ? TerminalStyle.accent : nil, cornerRadius: 8))
        )
        .accessibilityLabel("\(preset.rawValue) slippage")
        .accessibilityAddTraits(draft.slippage == preset ? .isSelected : [])
      }
    }
    .terminalGlassGroup()
  }

  private func changeSide(_ side: TradeSide) {
    if side == .buy && exitDraft.isEnabled {
      exitDraft.setEnabled(false, reference: referencePrice ?? asset.priceUsd)
    }
    draft.selectQuoteSide(side)
    amountFocused = true
  }
}
