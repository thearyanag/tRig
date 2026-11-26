import SwiftUI

struct RelayExecutionButton: View {
  let request: ExecutionQuoteRequest
  let wallet: TradingWallet
  let account: WalletAccount
  let quote: ExecutionQuote

  @Environment(WalletStore.self) private var store
  @State private var plan: RelayTradePlan?
  @State private var preparing = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Button {
        preparing = true
        error = nil
        Task {
          defer { preparing = false }
          do { plan = try await RelayTradeClient().prepare(request, quote: quote) }
          catch { self.error = error.localizedDescription }
        }
      } label: {
        Text(preparing ? "Preparing…" : "Review Relay trade")
          .font(AppTypography.bodySemibold)
          .frame(maxWidth: .infinity, minHeight: 36)
      }
      .buttonStyle(TerminalControlStyle.primary)
      .disabled(preparing || !quote.isFresh(at: .now) || !quote.matches(request)
        || request.context.sender?.lowercased() != account.address.lowercased())
      if let error {
        Text(error).font(AppTypography.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .sheet(item: $plan) { plan in
      RelayTradeReview(plan: plan, wallet: wallet, account: account, quote: quote)
        .environment(store)
    }
  }
}

private struct RelayTradeReview: View {
  let plan: RelayTradePlan
  let wallet: TradingWallet
  let account: WalletAccount
  let quote: ExecutionQuote

  @Environment(WalletStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var busy = false
  @State private var error: String?
  @State private var activity: WalletTradeActivity?

  private var isApproval: Bool { plan.action == .approve }
  private var isCrossChain: Bool { plan.request.input.chain != plan.request.output.chain }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { clock in
      VStack(alignment: .leading, spacing: 14) {
        Text(isApproval ? "Review token approval" : isCrossChain ? "Review bridge" : "Review swap")
          .font(AppTypography.title2Semibold)
        if let activity {
          let status = store.trades.entries.first { $0.id == activity.id }?.status ?? activity.status
          LabeledContent("Status", value: status.label)
          if isApproval && status == .confirmed {
            Text("Get a fresh trade quote to continue.")
          } else if status == .pending {
            Text("Track confirmation in Wallet → Activity.")
          }
          Text(verbatim: activity.transactionID)
            .font(AppTypography.caption).monospaced().textSelection(.enabled)
        } else {
          LabeledContent("Funding wallet", value: "\(wallet.label) · \(account.shortAddress)")
          if isCrossChain && !isApproval {
            LabeledContent("Networks", value: "\(plan.inputNetwork) → \(plan.outputNetwork)")
          } else {
            LabeledContent("Network", value: plan.inputNetwork)
          }
          LabeledContent("Available", value: "\(plan.payBalance) \(quote.input.symbol)")
          LabeledContent(isApproval ? "Approval amount" : "You pay",
            value: "\(plan.request.amount) \(quote.input.symbol)")
          if isApproval {
            Text("Spender").foregroundStyle(.secondary)
            Text(verbatim: plan.depository).font(AppTypography.caption).monospaced()
              .textSelection(.enabled)
            Text("This gives Relay permission to spend the quoted amount. Review the trade separately after confirmation.")
              .font(AppTypography.caption).foregroundStyle(.secondary)
          } else {
            LabeledContent("Estimated receive", value: "\(plan.receiveAmount) \(quote.output.symbol)")
            LabeledContent("Minimum receive", value: "\(plan.minimumReceive) \(quote.output.symbol)")
            if quote.minimumReceive != plan.minimumReceive {
              Text("The executable quote updated since the preview.")
                .font(AppTypography.caption).foregroundStyle(.secondary)
            }
            Text("Destination address").foregroundStyle(.secondary)
            Text(verbatim: plan.request.context.recipient ?? account.address)
              .font(AppTypography.caption).monospaced().textSelection(.enabled)
          }
          LabeledContent("Estimated origin gas", value: "\(plan.fee) \(plan.feeSymbol)")
          if clock.date >= plan.expiry {
            Text("This review expired. Get a fresh quote.").foregroundStyle(.orange)
          }
        }
        if let error { Text(error).foregroundStyle(.orange) }
        HStack {
          Spacer()
          Button(activity == nil ? "Cancel" : "Done") { dismiss() }
            .keyboardShortcut(.cancelAction).disabled(busy)
          if activity == nil {
            Button {
              unlockOrSubmit()
            } label: {
              Text(busy ? "Working…" : !store.isUnlocked ? "Unlock wallet" :
                isApproval ? "Approve token" : isCrossChain ? "Confirm bridge" : "Confirm swap")
                .settingsActionLabel()
            }
            .buttonStyle(TerminalControlStyle.primary)
            .disabled(busy || clock.date >= plan.expiry)
          }
        }
      }
      .font(AppTypography.callout)
      .padding(20).frame(width: 460)
    }
    .interactiveDismissDisabled(busy)
  }

  private func unlockOrSubmit() {
    busy = true
    error = nil
    Task {
      defer { busy = false }
      do {
        if !store.isUnlocked {
          try await store.unlock()
          return
        }
        let title = isApproval ? "Approve \(plan.request.amount) \(quote.input.symbol)" :
          "\(isCrossChain ? "Bridge" : "Swap") \(quote.input.symbol) to \(quote.output.symbol)"
        let approvalPrefix = "\(account.identityAddress):\(plan.token.lowercased()):"
        if isApproval, store.trades.entries.contains(where: {
          $0.details.provider == .relayApproval && $0.details.chain == plan.request.input.chain
            && $0.details.requestID.hasPrefix(approvalPrefix) && $0.status == .pending
        }) {
          throw WalletFailure("A Relay approval for this token is pending. Check Activity before trying again.")
        }
        activity = try await store.performTradeStep(
          operation: .relayEVM, plan: plan, wallet: wallet, account: account,
          activity: WalletTradeDetails(
            provider: isApproval ? .relayApproval : .relay,
            title: title, chain: plan.request.input.chain,
            requestID: isApproval ? approvalPrefix + plan.nonce : plan.requestId,
            expiresAt: plan.expiry)
        ) { signed in
          try await RelayTradeClient().submit(signed, chain: plan.request.input.chain)
        }
      } catch { self.error = error.localizedDescription }
    }
  }
}
