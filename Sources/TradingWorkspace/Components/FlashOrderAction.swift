import SwiftUI

struct FlashOrderAction: View {
  let asset: Asset
  let request: ExecutionQuoteRequest
  let walletStore: WalletStore
  let wallet: TradingWallet
  let account: WalletAccount
  var takeProfit = false
  var label = "Review order"

  @State private var pending: Review?
  @State private var loading: Task<Void, Never>?
  @State private var message: String?
  @State private var placed = false

  private struct Review: Identifiable {
    let data: FlashOrderReview
    let request: ExecutionQuoteRequest
    var id: String { data.signPlan.planId }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        preview()
      } label: {
        HStack(spacing: 6) {
          if loading != nil { ProgressView().controlSize(.mini) }
          Text(loading == nil ? label : "Checking funding…")
        }
        .font(AppTypography.calloutMedium).frame(maxWidth: .infinity).frame(height: 34)
      }
      .buttonStyle(TerminalControlStyle(fill: TerminalStyle.field))
      .disabled(!request.isValid || loading != nil || walletStore.submitting)
      if let message {
        Text(message)
          .font(AppTypography.caption).foregroundStyle(placed ? Color.secondary : .orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .sheet(item: $pending) { item in
      FlashOrderConfirmation(
        asset: asset, request: item.request, review: item.data,
        walletStore: walletStore, wallet: wallet, account: account
      ) { result in
        placed = true
        message = result
      }
    }
    .onChange(of: request) { _, _ in reset() }
    .onChange(of: account) { _, _ in reset() }
    .onDisappear { loading?.cancel() }
  }

  private func preview() {
    reset()
    loading = Task {
      defer { if !Task.isCancelled { loading = nil } }
      do {
        let review = try await FlashOrderClient().prepare(request, account: account, takeProfit: takeProfit)
        try Task.checkCancellation()
        pending = Review(data: review, request: request)
      } catch {
        if !Task.isCancelled { message = error.localizedDescription }
      }
    }
  }

  private func reset() {
    loading?.cancel()
    loading = nil
    pending = nil
    message = nil
    placed = false
  }

  static func family(for request: ExecutionQuoteRequest) -> WalletFamily? {
    guard request.input.chain == request.output.chain else { return nil }
    if request.input.chain == "solana" { return .solana }
    guard request.input.chain.hasPrefix("eip155:"),
      [request.input.address, request.output.address].allSatisfy({
        let address = $0.lowercased()
        return address.hasPrefix("0x") && address.count == 42
          && address != "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
          && address != "0x0000000000000000000000000000000000000000"
      })
    else { return nil }
    return .evm
  }
}

private struct FlashOrderConfirmation: View {
  @Environment(\.dismiss) private var dismiss
  let asset: Asset
  let request: ExecutionQuoteRequest
  let review: FlashOrderReview
  let walletStore: WalletStore
  let wallet: TradingWallet
  let account: WalletAccount
  let placed: (String) -> Void
  @State private var working = false
  @State private var attempted = false
  @State private var issue: String?

  private var spendSymbol: String {
    flashSymbol(request.input, default: request.side == "buy" ? asset.settlement?.symbol ?? "Quote token" : asset.symbol)
  }
  private var receiveSymbol: String {
    flashSymbol(request.output, default: request.side == "buy" ? asset.symbol : asset.settlement?.symbol ?? "Quote token")
  }

  private func flashSymbol(_ token: ExecutionTokenRef, default fallback: String) -> String {
    token.chain == "solana" && token.address == "So11111111111111111111111111111111111111112" ? "wSOL" : fallback
  }
  private var isStop: Bool { review.orderType == "stop-loss" || review.orderType == "take-profit" }
  private var title: String {
    switch review.orderType {
    case "take-profit": "Place take-profit order"
    case "stop-loss": "Place stop-loss order"
    default: "Place limit order"
    }
  }
  private var confirmTitle: String {
    if review.solanaSetup != nil { return "Set up token" }
    if review.approval != nil { return "Approve token" }
    return title
  }
  private var note: String {
    if review.solanaSetup != nil {
      return "Review the setup, then wait for it to confirm in Activity before reviewing the order again."
    }
    if review.approval != nil {
      return "Approve this exact amount first. Once the transaction confirms, review the order again to place it."
    }
    if isStop { return "Flash monitors this trigger. If it fires, the fill price can differ from the trigger price." }
    return "Flash monitors this limit and can fill it in parts. Available balance is shared with other orders."
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { clock in
      VStack(alignment: .leading, spacing: 13) {
        Text(title).font(AppTypography.title2Semibold)
        LabeledContent("Funding wallet", value: "\(wallet.label) · \(account.shortAddress)")
        LabeledContent("Asset", value: "\(asset.symbol) · \(asset.network)")
        LabeledContent("Maximum spend", value: "\(request.amount) \(spendSymbol)")
        LabeledContent("Wallet balance", value: "\(PortfolioFormat.quantity(review.availableAmount)) \(review.solanaSetup?.setup.wrap == true ? "SOL" : spendSymbol)")
        if let price = request.limitPriceUsd ?? request.triggerPriceUsd {
          LabeledContent(isStop ? "Trigger price" : "Limit price", value: "$\(price) / \(asset.symbol)")
        }
        LabeledContent("Estimated receive", value: "\(PortfolioFormat.quantity(review.receiveAmount)) \(receiveSymbol)")
        LabeledContent("Estimated fee", value: PortfolioFormat.currency(review.feeUsd))
        LabeledContent("Order expires", value: review.signPlan.orderExpiry.formatted(date: .abbreviated, time: .shortened))
        if let approval = review.approval {
          Divider()
          LabeledContent("Authorize for Flash", value: "\(request.amount) \(spendSymbol)")
          LabeledContent("Spender", value: approval.spender)
            .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
          LabeledContent("Approval gas", value: "\(approval.feeNative) \(approval.feeSymbol)")
        }
        if let setup = review.solanaSetup {
          Divider()
          if setup.setup.wrap {
            LabeledContent("Wrap into wSOL", value: "\(request.amount) SOL")
          }
          if setup.newAccounts > 0 {
            LabeledContent("New token accounts", value: String(setup.newAccounts))
            LabeledContent("Account rent", value: setup.rentSOL)
          }
          if setup.setup.delegate {
            LabeledContent("Delegate to Flash", value: "\(request.amount) \(spendSymbol)")
          }
          LabeledContent("Setup network fee", value: setup.feeSOL)
        }
        Text(note)
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let issue {
          Text(issue).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else if review.signPlan.expiry <= clock.date {
          Text("This review expired. Close it and get a fresh quote.").foregroundStyle(.orange)
        }
        HStack {
          Button("Back") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
          Spacer()
          Button(working ? "Submitting…" : confirmTitle, action: submit)
            .buttonStyle(.borderedProminent)
            .disabled(working || attempted || review.signPlan.expiry <= clock.date || walletStore.submitting)
        }
      }
      .padding(20).frame(width: 460).font(AppTypography.callout)
    }
    .interactiveDismissDisabled(working)
  }

  private func submit() {
    guard !working, !attempted else { return }
    working = true
    issue = nil
    Task {
      defer { working = false }
      do {
        if !walletStore.isUnlocked { try await walletStore.unlock() }
        if let setup = review.solanaSetup {
          try await setupSolana(setup)
          return
        }
        if let approval = review.approval {
          try await authorize(approval.plan)
          return
        }
        let plan = review.signPlan
        _ = try await walletStore.authorizeTrade(
          operation: .flashOrder, plan: plan, wallet: wallet, account: account, expiresAt: plan.expiry
        ) { signed in
          attempted = true
          return try await FlashOrderClient().submit(plan: plan, signature: signed)
        }
        walletStore.refreshBalances()
        placed("Order submitted. Track it in Markets → Orders.")
        dismiss()
      } catch {
        issue = error.localizedDescription
      }
    }
  }

  private func authorize(_ plan: FlashAllowancePlan) async throws {
    let activity = WalletTradeDetails(
      provider: .flashApproval, title: "Approve \(request.amount) \(spendSymbol) for Flash",
      chain: request.input.chain,
      requestID: "flash-approval:\(request.input.chain):\(account.identityAddress):\(plan.token.lowercased())",
      expiresAt: plan.expiry
    )
    let result = try await walletStore.performTradeStep(
      operation: .flashApproval, plan: plan, wallet: wallet, account: account, activity: activity
    ) { transaction in
      attempted = true
      try await FlashOrderClient().approve(plan: plan, transaction: transaction)
      return .pending
    }
    switch result.status {
    case .confirmed:
      placed("Approval confirmed. Review a fresh order to place it.")
    case .pending:
      placed("Check approval in Activity. Review a fresh order after it confirms.")
    case .failed, .expired:
      placed("Approval failed. Review a fresh order to try again.")
    }
    dismiss()
  }

  private func setupSolana(_ plan: FlashSolanaSetupPlan) async throws {
    let activity = WalletTradeDetails(
      provider: .flashApproval, title: "Set up \(spendSymbol) for Flash",
      chain: "solana",
      requestID: "flash-setup:solana:\(account.identityAddress):\(plan.setup.inputMint)",
      expiresAt: plan.expiry,
      lastValidBlockHeight: plan.lastValidBlockHeight
    )
    let result = try await walletStore.performTradeStep(
      operation: .flashSolanaSetup, plan: plan, wallet: wallet, account: account, activity: activity
    ) { transaction in
      attempted = true
      try await FlashOrderClient().setupSolana(plan: plan, transaction: transaction)
      return .pending
    }
    switch result.status {
    case .confirmed:
      placed("Setup confirmed. Review a fresh order to place it.")
    case .pending:
      placed("Check setup in Activity. Review a fresh order after it confirms.")
    case .failed, .expired:
      placed("Setup failed. Review a fresh order to try again.")
    }
    dismiss()
  }
}
