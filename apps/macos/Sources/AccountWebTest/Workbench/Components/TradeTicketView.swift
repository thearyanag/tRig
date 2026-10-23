import SwiftUI

struct TradeTicketView: View {
  let asset: Asset
  var market: SampleMarket = .backpack
  var priceLabel = "Sample price"
  @Binding var draft: TradeDraft
  @State private var review: TradePreview?
  @FocusState private var amountFocused: Bool

  private var isBuying: Bool { draft.side == .buy }
  private var paySymbol: String { isBuying ? "USDC" : asset.symbol }
  private var balance: Decimal { isBuying ? market.usdcBalance : market.assetBalance }
  private var result: Result<TradePreview, TradeInputError> {
    draft.preview(asset: asset, market: market)
  }
  private var preview: TradePreview? { try? result.get() }
  private var error: TradeInputError? {
    if case .failure(let error) = result { return error }
    return nil
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Market trade").font(.headline)
          Spacer()
          Text("Sample balances").font(.caption).foregroundStyle(.secondary)
        }
        Picker("Trade side", selection: $draft.side) {
          ForEach(TradeSide.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("You pay").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(paySymbol).font(.callout.weight(.medium))
          }
          TextField("0.00", text: $draft.amountText)
            .textFieldStyle(.plain)
            .font(.system(size: 24, weight: .medium)).monospacedDigit()
            .focused($amountFocused)
            .accessibilityLabel("Amount in \(paySymbol)")
            .onSubmit(openReview)
          Text("Available: \(DisplayFormat.number(balance)) \(paySymbol)")
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        HStack(spacing: 8) {
          ForEach([25, 50, 75, 100], id: \.self) { percent in
            Button(percent == 100 ? "Max" : "\(percent)%") {
              draft.amountText = DisplayFormat.number(balance * Decimal(percent) / 100)
                .replacingOccurrences(of: ",", with: "")
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Use \(percent) percent of sample \(paySymbol) balance")
          }
        }
        .controlSize(.small)
        if let error {
          Text(error.rawValue).font(.caption)
            .foregroundStyle(error == .empty ? Color.secondary : Color.orange)
            .accessibilityLabel("Amount validation: \(error.rawValue)")
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Estimated receive").font(.caption).foregroundStyle(.secondary)
          HStack(alignment: .firstTextBaseline) {
            Text(isBuying ? asset.symbol : "USDC").foregroundStyle(.secondary)
            Spacer()
            Text(preview.map { DisplayFormat.number($0.receiveAmount) } ?? "—")
              .font(.title2.weight(.semibold)).monospacedDigit()
          }
        }
        Divider()
        VStack(spacing: 8) {
          detail(
            priceLabel,
            value: DisplayFormat.currency(
              market.price,
              decimals: DisplayFormat.priceDecimals(
                NSDecimalNumber(decimal: market.price).doubleValue)))
          detail(
            "Sample fee (0.1%)",
            value: preview.map { "\(DisplayFormat.number($0.feeUSDC)) USDC" } ?? "—")
          HStack {
            Text("Slippage").foregroundStyle(.secondary)
            Spacer()
            Picker("Slippage tolerance", selection: $draft.slippage) {
              ForEach(SlippagePreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
          }
          detail(
            "Minimum receive",
            value: preview.map {
              "\(DisplayFormat.number($0.minimumReceive)) \($0.receiveSymbol)"
            } ?? "—")
        }
        .font(.caption)
      }
      .padding(16)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        Divider()
        VStack(alignment: .leading, spacing: 10) {
          Button(action: openReview) {
            Text("Review \(draft.side.rawValue.lowercased())")
              .font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 5)
          }
          .buttonStyle(.borderedProminent)
          .tint(isBuying ? .green : .red)
          .disabled(preview == nil)
          Label("Local estimate only. No order will be placed.", systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
      }
      .background(.background)
    }
    .sheet(item: $review) { TradeReviewView(asset: asset, preview: $0) }
  }

  private func detail(_ title: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).foregroundStyle(.secondary)
      Spacer(minLength: 10)
      Text(value).monospacedDigit().multilineTextAlignment(.trailing)
    }
  }
  private func openReview() {
    guard let preview else { return }
    amountFocused = false
    review = preview
  }
}

#Preview {
  TradeTicketView(asset: .backpack, draft: .constant(TradeDraft())).frame(width: 340, height: 700)
}
