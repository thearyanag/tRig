import SwiftUI

struct SwapQuoteTicketView: View {
  let asset: Asset
  @Binding var draft: TradeDraft
  var referencePrice: Double? = nil
  @State private var store = SwapQuoteStore()
  @State private var review: SwapQuote?
  @FocusState private var amountFocused: Bool
  private var input: SwapQuoteInput { SwapQuoteInput(asset: asset, draft: draft) }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let quote = store.visibleQuote(for: input)
      let fresh = quote?.isFresh(at: context.date) == true
      ScrollView {
        VStack(spacing: 8) {
          sideTabs
          orderMode
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
          .buttonStyle(
            TerminalControlStyle(
              fill: TerminalStyle.accent, foreground: .white, border: TerminalStyle.accent)
          )
          .disabled(!input.isValid || store.isLoading)
          Text("Jupiter quotes exclude wallet costs. No order is placed.")
            .font(AppTypography.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).background(TerminalStyle.panel)
        .overlay(alignment: .top) { Divider() }
      }
    }
    .font(AppTypography.body).background(TerminalStyle.panel)
    .onChange(of: input) { _, value in
      if store.input != value { store.clear() }
      review = nil
    }
    .onDisappear { store.clear() }
    .sheet(item: $review) { SwapQuoteReviewView(quote: $0) }
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
            border: selected ? tint : TerminalStyle.border)
        )
        .accessibilityLabel("\(side.rawValue) \(asset.symbol)")
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
  }

  private var orderMode: some View {
    HStack(spacing: 4) {
      Text("Market").font(AppTypography.calloutMedium)
        .frame(maxWidth: .infinity).frame(height: 28)
        .background(
          TerminalStyle.panel, in: RoundedRectangle(cornerRadius: TerminalStyle.controlRadius)
        )
        .overlay(
          RoundedRectangle(cornerRadius: TerminalStyle.controlRadius).strokeBorder(
            .white.opacity(0.16))
        )
        .accessibilityLabel("Market swap quote")
      Text("Limit").font(AppTypography.callout)
        .foregroundStyle(.tertiary).frame(maxWidth: .infinity).frame(height: 28)
        .background(
          TerminalStyle.field.opacity(0.5),
          in: RoundedRectangle(cornerRadius: TerminalStyle.controlRadius)
        )
        .overlay(
          RoundedRectangle(cornerRadius: TerminalStyle.controlRadius).strokeBorder(
            TerminalStyle.border)
        )
        .help("Limit orders are not available yet.").accessibilityLabel("Limit orders unavailable")
    }
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
              ? TerminalStyle.accent.opacity(0.5) : TerminalStyle.border)
        )
        .accessibilityLabel("\(preset.rawValue) slippage")
        .accessibilityAddTraits(draft.slippage == preset ? .isSelected : [])
      }
    }
  }

  private func changeSide(_ side: TradeSide) {
    draft.selectQuoteSide(side)
    amountFocused = true
  }
}
