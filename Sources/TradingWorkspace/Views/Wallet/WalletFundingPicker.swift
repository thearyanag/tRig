import SwiftUI

struct WalletFundingPicker: View {
  @Environment(WalletStore.self) private var store
  let family: WalletFamily
  @Binding var selection: UUID?

  var body: some View {
    let wallets = store.wallets.filter { $0.accounts.contains { $0.family == family } }
    HStack(spacing: 8) {
      Image(systemName: "wallet.bifold").foregroundStyle(.secondary)
      Text("Wallet").foregroundStyle(.secondary)
      Spacer(minLength: 0)
      if wallets.isEmpty {
        Text("Add a \(family.title) wallet").foregroundStyle(.secondary)
      } else {
        Picker("Funding wallet", selection: Binding(
          get: { selection ?? wallets.first?.id },
          set: { selection = $0 })
        ) {
          ForEach(wallets) { wallet in
            if let account = wallet.accounts.first(where: { $0.family == family }) {
              Text("\(wallet.label) · \(account.shortAddress)").tag(Optional(wallet.id))
            }
          }
        }
        .labelsHidden().pickerStyle(.menu)
        .disabled(store.submitting)
      }
    }
    .font(AppTypography.caption)
  }
}
