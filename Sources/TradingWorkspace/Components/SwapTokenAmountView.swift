import AppKit
import SwiftUI

struct SwapTokenAmountView: View {
  let title: String
  let asset: Asset
  let usesUSDC: Bool
  @Binding var amount: String
  let editable: Bool
  let fiatValue: String?
  let amountFocused: FocusState<Bool>.Binding
  let selectToken: (Bool) -> Void
  var submit: () -> Void = {}
  private var symbol: String { usesUSDC ? asset.settlement?.symbol ?? "Quote token" : asset.symbol }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(AppTypography.caption).foregroundStyle(.secondary)
      HStack(spacing: 8) {
        tokenIcon
        Menu {
          Button(asset.settlement?.symbol ?? "Quote token") { selectToken(true) }
          Button(asset.symbol) { selectToken(false) }
        } label: {
          Text(symbol).font(AppTypography.calloutMedium).lineLimit(1)
            .frame(minWidth: 54, maxWidth: 78, alignment: .leading).frame(height: 40)
            .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .tint(.primary)
        .disabled(asset.id == SwapQuoteInput.usdc)
        .accessibilityLabel("\(title) token, \(symbol)")
        .help("Switch between USDC and \(asset.symbol)")
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
          .foregroundStyle(.secondary).accessibilityHidden(true)
        Divider().frame(height: 22)
        if editable {
          TextField("0.00", text: $amount)
            .textFieldStyle(.plain).multilineTextAlignment(.trailing)
            .font(AppTypography.font(size: 18, weight: .medium)).monospacedDigit()
            .focused(amountFocused)
            .accessibilityLabel("Quote amount in \(symbol)")
            .onSubmit(submit)
        } else {
          Text(amount.isEmpty ? "—" : amount)
            .font(AppTypography.font(size: 18, weight: .medium)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.55)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("Estimated receive, \(amount) \(symbol)")
        }
      }
      .padding(.horizontal, 10).frame(height: 40)
      .background(
        TerminalStyle.field, in: RoundedRectangle(cornerRadius: TerminalStyle.quoteFieldRadius)
      )
      .overlay(
        RoundedRectangle(cornerRadius: TerminalStyle.quoteFieldRadius).strokeBorder(
          editable && amountFocused.wrappedValue ? TerminalStyle.accent : TerminalStyle.border))
      if let fiatValue {
        Text(fiatValue).font(AppTypography.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing).monospacedDigit()
      }
    }
  }

  @ViewBuilder private var tokenIcon: some View {
    if usesUSDC, asset.settlement?.symbol != "USDC" {
      Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.secondary).frame(
        width: 20, height: 20)
    } else if usesUSDC, let url = Bundle.main.resourceURL?.appendingPathComponent("Icons/usdc.png"),
      let icon = NSImage(contentsOf: url)
    {
      Image(nsImage: icon).resizable().scaledToFit().frame(width: 20, height: 20)
    } else if usesUSDC {
      Image(systemName: "dollarsign.circle.fill").foregroundStyle(.blue)
        .frame(width: 20, height: 20)
    } else {
      AssetIconView(asset: asset, size: 20)
    }
  }
}
