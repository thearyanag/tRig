import SwiftUI

struct JupiterTriggerOrderAction: View {
  let asset: Asset
  let request: ExecutionQuoteRequest
  let walletStore: WalletStore
  let wallet: TradingWallet
  let account: WalletAccount
  let title: String

  @State private var reviewing = false

  private var intent: JupiterPriceOrderIntent? {
    JupiterPriceOrderIntent(asset: asset, request: request, account: account)
  }

  var body: some View {
    Button { reviewing = true } label: {
      Text("Review \(title)").font(AppTypography.calloutMedium)
        .frame(maxWidth: .infinity).frame(height: 35)
    }
    .buttonStyle(TerminalControlStyle.primary)
    .disabled(intent == nil || walletStore.submitting)
    .sheet(isPresented: $reviewing) {
      if let intent {
        JupiterTriggerDepositConfirmation(
          intent: intent, title: title,
          spendSymbol: request.side == "buy" ? asset.settlement?.symbol ?? "Quote token" : asset.symbol,
          triggerSymbol: asset.symbol, walletStore: walletStore, wallet: wallet, account: account)
      }
    }
    .onChange(of: intent) { _, _ in reviewing = false }
  }
}

private struct JupiterTriggerDepositConfirmation: View {
  @Environment(\.dismiss) private var dismiss
  let intent: JupiterPriceOrderIntent
  let title: String
  let spendSymbol: String
  let triggerSymbol: String
  let walletStore: WalletStore
  let wallet: TradingWallet
  let account: WalletAccount

  @State private var session: JupiterTriggerSessionStatus?
  @State private var review: JupiterTriggerDepositReview?
  @State private var activity: WalletTradeActivity?
  @State private var orderID: String?
  @State private var working = false
  @State private var error: String?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { clock in
      VStack(alignment: .leading, spacing: 14) {
        Text("Review \(title)").font(AppTypography.title2Semibold)
        if let activity {
          receipt(activity)
        } else {
          terms
          if let review, review.expiry <= clock.date {
            Text("The deposit review expired. Refresh to continue.").foregroundStyle(.orange)
          }
        }
        if let error { Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        Divider()
        actions(now: clock.date)
      }
      .font(AppTypography.callout)
      .padding(22).frame(width: 475)
    }
    .background(TerminalStyle.canvas)
    .interactiveDismissDisabled(working)
    .task { await loadReview() }
    .onChange(of: walletStore.isUnlocked && !walletStore.submitting) { _, canSignIn in
      if canSignIn, session?.authenticated == false { resumeReview() }
    }
  }

  private var terms: some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent("Funding wallet", value: "\(wallet.label) · \(account.shortAddress)")
      LabeledContent("Vault deposit", value:
        "\(JupiterSwapPlan.units(intent.inputAmount, decimals: intent.inputDecimals)) \(spendSymbol)")
      LabeledContent("Trigger", value:
        "\(triggerSymbol) \(intent.triggerCondition.rawValue) $\(intent.triggerPriceUsd)")
      LabeledContent("Slippage", value: "\(DisplayFormat.number(Decimal(intent.slippageBps) / 100, decimals: 2))%")
      if let review {
        LabeledContent("Vault address") {
          Text(verbatim: review.signingPlan.vault).font(AppTypography.caption).monospaced()
            .textSelection(.enabled)
        }
        LabeledContent("Network fee", value: "\(JupiterSwapPlan.units(review.feeLamports, decimals: 9)) SOL")
        if review.rentLamports != "0" {
          LabeledContent("Account rent", value: "\(JupiterSwapPlan.units(review.rentLamports, decimals: 9)) SOL")
        }
        LabeledContent("Order expires", value: review.orderExpiry.formatted(date: .abbreviated, time: .shortened))
      }
      Text("Jupiter holds this deposit in your Privy-managed vault. Use Orders to withdraw unused funds after cancellation or expiry.")
        .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func receipt(_ entry: WalletTradeActivity) -> some View {
    let status = walletStore.trades.entries.first { $0.id == entry.id }?.status ?? entry.status
    return VStack(alignment: .leading, spacing: 8) {
      LabeledContent("Deposit status", value: status.label)
      if let orderID {
        LabeledContent("Order ID") { Text(verbatim: orderID).textSelection(.enabled) }
      }
      Text(verbatim: entry.transactionID).font(AppTypography.caption).monospaced().textSelection(.enabled)
      Text("Check Orders for the current order status.").foregroundStyle(.secondary)
    }
  }

  private func actions(now: Date) -> some View {
    HStack {
      Button(activity == nil ? "Cancel" : "Done") { dismiss() }
        .keyboardShortcut(.cancelAction).disabled(working)
      Spacer()
      if working {
        ProgressView().controlSize(.small)
      } else if activity == nil {
        if session == nil {
          Button("Retry") { Task { await loadReview() } }.buttonStyle(.borderedProminent)
        } else if session?.authenticated == false {
          Button(walletStore.isUnlocked ? "Retry" : "Unlock wallet") {
            Task { await loadReview(unlockIfNeeded: true) }
          }
            .buttonStyle(.borderedProminent).disabled(walletStore.submitting)
        } else if let review, review.expiry > now {
          Button(walletStore.isUnlocked ? "Deposit and place order" : "Unlock wallet") {
            Task { await confirm(review) }
          }.buttonStyle(.borderedProminent).disabled(walletStore.submitting)
        } else {
          Button("Refresh review") { Task { await loadReview() } }.buttonStyle(.borderedProminent)
        }
      }
    }
  }

  private func resumeReview() {
    guard !working, activity == nil else { return }
    Task { await loadReview() }
  }

  private func loadReview(unlockIfNeeded: Bool = false) async {
    guard !working else { return }
    working = true
    error = nil
    review = nil
    defer { working = false }
    do {
      let current = try await JupiterTriggerSession().authenticate(
        walletStore: walletStore, wallet: wallet, account: account, unlockIfNeeded: unlockIfNeeded)
      try Task.checkCancellation()
      session = current
      if session?.authenticated == true {
        review = try await JupiterTriggerOrderClient().prepare(intent)
      }
    } catch is CancellationError {
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func confirm(_ review: JupiterTriggerDepositReview) async {
    guard !working, review.matches(intent) else { return }
    working = true
    error = nil
    defer { working = false }
    do {
      if !walletStore.isUnlocked {
        try await walletStore.unlock()
        return
      }
      activity = try await walletStore.performTradeStep(
        operation: .jupiterTriggerTransfer, plan: review.signingPlan, wallet: wallet, account: account,
        activity: WalletTradeDetails(
          provider: .jupiterTrigger, title: "Vault deposit · \(title)", chain: "solana",
          requestID: review.planId, expiresAt: review.expiry,
          lastValidBlockHeight: review.lastValidBlockHeight)
      ) { signed in
        let receipt = try await JupiterTriggerOrderClient().submit(signed, review: review)
        orderID = receipt.orderId
        return receipt.confirmed ? .confirmed : .pending
      }
    } catch is CancellationError {
    } catch {
      self.error = error.localizedDescription
    }
  }
}
