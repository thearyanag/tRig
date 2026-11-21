import SwiftUI

struct ExitLegEditor: View {
  let kind: ExitLegKind
  let asset: Asset
  @Binding var leg: ExitLegDraft
  let slippage: SlippagePreset
  let referencePrice: Double?
  let store: ExecutionQuoteStore
  @State private var showDetails = false

  private var tint: Color { kind == .takeProfit ? TerminalStyle.buy : .orange }
  private var request: ExecutionQuoteRequest {
    leg.request(kind: kind, asset: asset, slippage: slippage)
  }
  private var validation: String? { leg.validation(kind: kind, reference: referencePrice) }
  private var enabled: Binding<Bool> {
    Binding(
      get: { leg.target.isEnabled },
      set: { leg.setEnabled($0, kind: kind, reference: referencePrice) })
  }
  private var price: Binding<String> {
    Binding(get: { leg.target.priceText }, set: { leg.target.setPrice($0) })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Toggle(kind.title, isOn: enabled).toggleStyle(.checkbox)
          .font(AppTypography.calloutMedium).foregroundStyle(tint)
        Spacer()
        Text("DRAFT").font(AppTypography.caption).foregroundStyle(.secondary)
      }
      if leg.target.isEnabled {
        HStack(alignment: .top, spacing: 8) {
          input("Price · USD", binding: price, label: "\(kind.title) price in USD")
          input(
            "Exit qty · \(asset.symbol)", binding: $leg.quantityText,
            label: "\(kind.title) exit quantity in \(asset.symbol)")
        }
        HStack(spacing: 4) {
          ForEach([5, 10, 25], id: \.self) { amount in
            let percent = kind == .takeProfit ? amount : -amount
            Button {
              leg.target.preset(percent, reference: referencePrice)
            } label: {
              Text("\(percent > 0 ? "+" : "−")\(amount)%")
                .font(AppTypography.caption).frame(maxWidth: .infinity).frame(height: 25)
            }
            .buttonStyle(.plain)
            .background(TerminalStyle.field)
            .overlay {
              RoundedRectangle(cornerRadius: TerminalStyle.controlRadius).strokeBorder(
                TerminalStyle.border)
            }
            .disabled(referencePrice == nil)
            .accessibilityLabel(
              "\(kind.title) \(amount) percent \(percent > 0 ? "above" : "below") market")
          }
        }
        if let validation {
          Text(validation).font(AppTypography.caption).foregroundStyle(.orange)
        } else if let target = leg.target.price, let referencePrice, referencePrice > 0 {
          Text(
            "\(DisplayFormat.number(Decimal(abs(target / referencePrice - 1) * 100), decimals: 1))% \(target > referencePrice ? "above" : "below") market"
          )
          .font(AppTypography.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        if !leg.quantityText.isEmpty && !ExecutionQuoteRequest.positive(request.amount) {
          Text("Enter a positive \(asset.symbol) quantity.").font(AppTypography.caption)
            .foregroundStyle(.orange)
        }
        TimelineView(.periodic(from: .now, by: 1)) { clock in
          if validation == nil, let quote = store.visible(for: request) {
            VStack(alignment: .leading, spacing: 6) {
              row(
                "Estimated receive",
                "\(PortfolioFormat.quantity(quote.receiveAmount)) \(quote.output.symbol)")
              DisclosureGroup(isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 6) {
                  row("Route", quote.providerName)
                  row(
                    "Minimum receive",
                    quote.minimumReceive.map {
                      "\(PortfolioFormat.quantity($0)) \(quote.output.symbol)"
                    }
                      ?? "Not supplied")
                  ForEach(Array(quote.fees.enumerated()), id: \.offset) { _, fee in
                    row(
                      fee.kind,
                      fee.amountUsd.map { PortfolioFormat.currency($0) }
                        ?? fee.rateBps.map {
                          DisplayFormat.number(Decimal($0) / 100, decimals: 2) + "%"
                        }
                        ?? "Not supplied")
                  }
                  ForEach(quote.warnings, id: \.self) { Text($0).foregroundStyle(.secondary) }
                }.padding(.top, 6)
              } label: {
                Text(
                  quote.isFresh(at: clock.date)
                    ? "Details · quoted \(max(0, Int(clock.date.timeIntervalSince1970 - quote.fetchedAt)))s ago"
                    : "Details · quote is stale"
                )
                .foregroundStyle(quote.isFresh(at: clock.date) ? Color.secondary : .orange)
              }.font(AppTypography.caption)
            }.padding(.top, 4)
          }
        }
        if store.isLoading {
          HStack {
            ProgressView().controlSize(.mini)
            Text("Getting \(kind.title.lowercased()) quote…")
          }
          .font(AppTypography.caption).foregroundStyle(.secondary)
        }
        if let error = store.error {
          Text(error).font(AppTypography.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(8).background(TerminalStyle.field.opacity(0.45))
    .overlay {
      RoundedRectangle(cornerRadius: TerminalStyle.controlRadius).strokeBorder(tint.opacity(0.3))
    }
    .onChange(of: request) { _, value in if store.request != value { store.clear() } }
    .onChange(of: validation) { _, _ in store.clear() }
    .onChange(of: leg.target.isEnabled) { _, _ in store.clear() }
  }

  private func input(_ title: String, binding: Binding<String>, label: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(AppTypography.caption).foregroundStyle(.secondary)
      TextField("0.00", text: binding).textFieldStyle(.plain)
        .font(AppTypography.font(size: 17, weight: .medium)).monospacedDigit()
        .padding(8).background(TerminalStyle.field)
        .overlay { Rectangle().strokeBorder(TerminalStyle.border) }
        .accessibilityLabel(label)
    }.frame(maxWidth: .infinity)
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(title).foregroundStyle(.secondary)
      Spacer(minLength: 2)
      Text(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
    }.font(AppTypography.caption)
  }
}
