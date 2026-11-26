import SwiftUI

struct WalletFamilyTabs: View {
  let families: [WalletFamily]
  @Binding var selection: WalletFamily

  var body: some View {
    if families.count > 1 {
      HStack(spacing: 4) {
        ForEach(families) { family in
          let selected = selection == family
          Button { selection = family } label: {
            Text(family.title)
              .font(AppTypography.calloutMedium)
              .frame(maxWidth: .infinity).frame(height: 30)
          }
          .buttonStyle(TerminalControlStyle(
            fill: selected ? TerminalStyle.accent : TerminalStyle.field,
            foreground: selected ? .white : .secondary,
            border: selected ? TerminalStyle.accent : TerminalStyle.border,
            glass: .init(tint: selected ? TerminalStyle.accent : nil)))
          .accessibilityAddTraits(selected ? .isSelected : [])
        }
      }
      .terminalGlassGroup()
      .terminalControlTrack(cornerRadius: 10)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Wallet chain")
    }
  }
}

extension View {
  func walletCard(padding: CGFloat = 12) -> some View {
    let shape = RoundedRectangle(cornerRadius: 10)
    return self.padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(TerminalStyle.field, in: shape)
      .overlay { shape.strokeBorder(TerminalStyle.border).allowsHitTesting(false) }
  }

  func walletField() -> some View {
    self.textFieldStyle(.plain).walletCard(padding: 10)
  }
}
