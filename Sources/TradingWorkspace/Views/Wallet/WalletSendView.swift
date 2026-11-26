import SwiftUI

struct WalletSendView: View {
  private enum SendAsset: Equatable {
    case native
    case holding(WalletHoldingToken)
    case custom

    static func == (lhs: Self, rhs: Self) -> Bool {
      switch (lhs, rhs) {
      case (.native, .native), (.custom, .custom): true
      case (.holding(let left), .holding(let right)): left.address == right.address
      default: false
      }
    }
  }

  let wallet: TradingWallet
  let network: WalletNetwork?
  let account: WalletAccount
  let balance: String?
  let availableNetworks: [WalletNetwork]
  @Binding var family: WalletFamily
  @Binding var networkID: String
  let onBack: () -> Void

  @Environment(WalletStore.self) private var store
  @State private var recipient = ""
  @State private var amount = ""
  @State private var sendAsset = SendAsset.native
  @State private var holdings: [WalletHoldingToken] = []
  @State private var customAddress = ""
  @State private var plan: WalletTransferPlan?
  @State private var transactionID: String?
  @State private var acknowledged = false
  @State private var reviewBusy = false
  @State private var error: String?
  @State private var reviewTask: Task<Void, Never>?

  private var validInput: Bool {
    guard let network, network.accepts(recipient.trimmingCharacters(in: .whitespacesAndNewlines)),
      QuoteAmount.isPositive(amount) else { return false }
    return sendAsset == .native || tokenAddress.map(network.accepts) == true
  }

  private var tokenAddress: String? {
    switch sendAsset {
    case .native: nil
    case .holding(let token): token.address
    case .custom: customAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private var sourceKey: String { "\(network?.id ?? ""):\(account.address)" }

  private func assetSymbol(_ network: WalletNetwork) -> String {
    switch sendAsset {
    case .native: network.symbol
    case .holding(let token): token.symbol
    case .custom: tokenAddress.map { "\($0.prefix(4))…\($0.suffix(4))" } ?? "Token"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Button {
          if transactionID != nil || plan == nil { onBack() } else { plan = nil; error = nil }
        } label: { Image(systemName: "chevron.left").frame(width: 20, height: 22) }
          .buttonStyle(.borderless).accessibilityLabel("Back").disabled(store.submitting || store.authorizing)
        Text(transactionID == nil ? plan == nil ? "Send" : "Review send" :
          acknowledged ? "Transfer submitted" : "Check transfer status")
          .font(AppTypography.headline)
      }
      if let transactionID {
        VStack(alignment: .leading, spacing: 10) {
          Text(acknowledged ? "Track confirmation in Wallet Activity." :
            "The network didn’t confirm submission. Check this transfer in Activity before sending again.")
            .font(AppTypography.callout).foregroundStyle(.secondary)
          Text("Transaction ID").font(AppTypography.caption).foregroundStyle(.secondary)
          Text(verbatim: transactionID).font(.system(size: 10, design: .monospaced))
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.walletCard()
        primaryAction("Done", action: onBack)
      } else if let plan, let network {
        review(plan, network: network)
      } else {
        input
      }
      if let error { Text(error).font(AppTypography.caption).foregroundStyle(.orange) }
    }
    .onDisappear { reviewTask?.cancel() }
    .onChange(of: sourceKey) {
      reviewTask?.cancel()
      reviewBusy = false
      plan = nil
      sendAsset = .native
      amount = ""
      customAddress = ""
      error = nil
    }
    .task(id: sourceKey) {
      holdings = []
      guard let network else { return }
      if let snapshot = try? await WalletHoldingsClient().holdings(network: network, account: account),
        !Task.isCancelled {
        holdings = snapshot.tokens.filter { $0.address != nil }
      }
    }
  }

  private var input: some View {
    VStack(alignment: .leading, spacing: 10) {
      WalletFamilyTabs(families: wallet.addressAccounts.map(\.family), selection: Binding(
        get: { family }, set: { selected in
          guard selected != family else { return }
          family = selected
          networkID = selected == .solana ? "solana" : ""
        }))
        .disabled(reviewBusy)
      if family == .evm {
        networkPicker
      }
      VStack(alignment: .leading, spacing: 8) {
        LabeledContent("From", value: account.shortAddress)
        if let network {
          assetPicker(network)
          switch sendAsset {
          case .native:
            if let balance {
              LabeledContent("Available", value: "\(balance) \(network.symbol)")
            }
          case .holding(let token):
            LabeledContent("Available", value: "\(token.quantity) \(token.symbol)")
          case .custom:
            EmptyView()
          }
        }
      }.font(AppTypography.caption).walletCard(padding: 10)
      if let network {
        if sendAsset == .custom {
          TextField(family == .solana ? "Token mint address" : "Token contract address", text: $customAddress)
            .walletField().disabled(reviewBusy)
        }
        TextField("Recipient address", text: $recipient).walletField().disabled(reviewBusy)
        TextField(sendAsset == .custom ? "Token amount" : "Amount (\(assetSymbol(network)))",
          text: $amount).walletField().disabled(reviewBusy)
        primaryAction(reviewBusy ? "Preparing…" : "Review send") { prepare(network) }
          .disabled(!validInput || reviewBusy)
      }
    }
  }

  private func assetPicker(_ network: WalletNetwork) -> some View {
    HStack {
      Text("Asset").foregroundStyle(.secondary)
      Spacer()
      Menu {
        Button(network.symbol) { select(.native) }
        if !holdings.isEmpty {
          Divider()
          ForEach(holdings, id: \.address) { token in
            Button("\(token.symbol) · \(token.name)") { select(.holding(token)) }
          }
        }
        Divider()
        Button("Enter token address…") { select(.custom) }
      } label: {
        Label(sendAsset == .custom ? "Custom token" : assetSymbol(network),
          systemImage: "chevron.down")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .accessibilityLabel("Asset")
      .disabled(reviewBusy)
    }
  }

  private func select(_ asset: SendAsset) {
    guard asset != sendAsset else { return }
    sendAsset = asset
    amount = ""
    customAddress = ""
    error = nil
  }

  private var networkPicker: some View {
    let choices = availableNetworks.filter { $0.family == .evm }
    return Menu {
      ForEach(choices) { item in
        Button {
          networkID = item.id
        } label: {
          if item.id == networkID { Label(item.name, systemImage: "checkmark") }
          else { Text(item.name) }
        }
      }
    } label: {
      HStack {
        Text("Network").foregroundStyle(.secondary)
        Spacer()
        Text(network?.name ?? (choices.isEmpty ? "Unavailable" : "Choose a network"))
        Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
      }
      .font(AppTypography.callout)
      .walletCard(padding: 10)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .accessibilityLabel(network.map { "Network, \($0.name)" } ?? "Choose EVM network")
    .disabled(reviewBusy || choices.isEmpty)
  }

  private func review(_ plan: WalletTransferPlan, network: WalletNetwork) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      VStack(alignment: .leading, spacing: 9) {
        LabeledContent("Network", value: network.name)
        LabeledContent("From", value: account.shortAddress)
        Divider()
        Text("Recipient").foregroundStyle(.secondary)
        Text(verbatim: plan.intent.to).font(.system(size: 10, design: .monospaced))
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        Divider()
        LabeledContent("Send", value: "\(plan.intent.amount) \(assetSymbol(network))")
        if let token = plan.intent.tokenAddress {
          Text(plan.parameters.spl?.program == .token2022 ? "Token-2022 mint"
            : network.family == .solana ? "Token mint" : "Token contract")
            .foregroundStyle(.secondary)
          Text(verbatim: token).font(.system(size: 10, design: .monospaced))
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        LabeledContent("Network fee (est.)", value: "\(plan.fee) \(network.symbol)")
        if let accountFee = plan.accountCreationFee {
          LabeledContent("Recipient account deposit", value: "\(accountFee) \(network.symbol)")
        }
      }.font(AppTypography.caption).walletCard()
      if store.isUnlocked {
        primaryAction(store.submitting ? "Submitting…" : "Confirm send") { submit(plan, network: network) }
          .disabled(store.submitting)
      } else {
        primaryAction(store.authorizing ? "Authenticating…" : "Unlock to send") {
          reviewTask = Task {
            do {
              try await store.unlock()
              // Authentication can outlast the original wallet network estimate.
              if plan.expired { prepare(network) }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
          }
        }
        .disabled(store.authorizing)
      }
    }
  }

  private func primaryAction(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(AppTypography.calloutMedium)
        .frame(maxWidth: .infinity).frame(height: 36)
    }.buttonStyle(TerminalControlStyle.primary)
  }

  private func prepare(_ network: WalletNetwork) {
    let intent = WalletTransferIntent(chain: network.id, from: account.address,
      to: recipient.trimmingCharacters(in: .whitespacesAndNewlines),
      amount: amount.trimmingCharacters(in: .whitespacesAndNewlines),
      tokenAddress: tokenAddress)
    reviewBusy = true; error = nil; plan = nil
    reviewTask = Task {
      defer { if !Task.isCancelled { reviewBusy = false } }
      do {
        let prepared = try await WalletTransferClient().prepare(intent)
        try Task.checkCancellation()
        plan = prepared
      }
      catch is CancellationError { }
      catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
  }

  private func submit(_ plan: WalletTransferPlan, network: WalletNetwork) {
    if plan.expired { prepare(network); return }
    error = nil
    let symbol = assetSymbol(network)
    Task {
      do {
        let (id, submitted) = try await store.send(
          plan, from: wallet, network: network, account: account, symbol: symbol)
        transactionID = id
        acknowledged = submitted
      } catch is CancellationError { }
      catch { self.error = error.localizedDescription }
    }
  }
}
