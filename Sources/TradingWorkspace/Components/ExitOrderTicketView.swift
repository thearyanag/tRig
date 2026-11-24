import SwiftUI

struct ExitOrderTicketView: View {
  let asset: Asset
  @Binding var exits: ExitOrderDraft
  @Binding var slippage: SlippagePreset
  let referencePrice: Double?
  @State private var takeProfitStore = ExecutionQuoteStore()
  @State private var stopLossStore = ExecutionQuoteStore()

  private var loading: Bool { takeProfitStore.isLoading || stopLossStore.isLoading }
  private func canPreview(_ leg: ExitLegDraft, _ kind: ExitLegKind) -> Bool {
    leg.target.isEnabled && leg.validation(kind: kind, reference: referencePrice) == nil
      && leg.request(kind: kind, asset: asset, slippage: slippage).isValid
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Exit targets").font(AppTypography.calloutMedium)
          Spacer()
          Text(
            referencePrice.map { "Current $\(LimitOrderDraft.formatted($0))" } ?? "Loading price…"
          )
          .font(AppTypography.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        ExitLegEditor(
          kind: .takeProfit, asset: asset, leg: $exits.takeProfit,
          slippage: slippage, referencePrice: referencePrice, store: takeProfitStore)
        ExitLegEditor(
          kind: .stopLoss, asset: asset, leg: $exits.stopLoss,
          slippage: slippage, referencePrice: referencePrice, store: stopLossStore)
        HStack(spacing: 4) {
          Text("Slippage").foregroundStyle(.secondary)
          Spacer()
          ForEach(SlippagePreset.allCases) { value in
            Button {
              slippage = value
            } label: {
              Text(value.rawValue).frame(width: 42, height: 26)
            }
            .buttonStyle(
              TerminalControlStyle(
                fill: slippage == value ? TerminalStyle.accent.opacity(0.15) : TerminalStyle.field,
                border: slippage == value ? TerminalStyle.accent : TerminalStyle.border)
            )
            .accessibilityLabel("\(value.rawValue) exit slippage")
          }
        }.font(AppTypography.caption)
        Text(
          "\(asset.hasChart ? "Drag either chart line or enter a price." : "Enter each target price.") Quantities are in \(asset.symbol)."
        )
        .font(AppTypography.caption).foregroundStyle(.secondary)
      }.padding(12)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Button {
          if canPreview(exits.takeProfit, .takeProfit) {
            takeProfitStore.load(
              exits.takeProfit.request(kind: .takeProfit, asset: asset, slippage: slippage))
          }
          if canPreview(exits.stopLoss, .stopLoss) {
            stopLossStore.load(
              exits.stopLoss.request(kind: .stopLoss, asset: asset, slippage: slippage))
          }
        } label: {
          HStack(spacing: 6) {
            if loading { ProgressView().controlSize(.mini) }
            Text(loading ? "Getting exit quotes…" : "Preview exits")
          }.font(AppTypography.bodySemibold).frame(maxWidth: .infinity).frame(height: 40)
        }
        .buttonStyle(TerminalControlStyle.primary)
        .disabled(
          loading
            || (!canPreview(exits.takeProfit, .takeProfit)
              && !canPreview(exits.stopLoss, .stopLoss))
        )
        Text("Independent quote previews. No orders are linked or placed.")
          .font(AppTypography.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }.padding(12).background(TerminalStyle.quotePanel)
        .overlay(alignment: .top) { Divider() }
    }
    .font(AppTypography.body)
    .onDisappear {
      takeProfitStore.clear()
      stopLossStore.clear()
    }
  }
}
