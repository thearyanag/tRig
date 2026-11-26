import SwiftUI

struct JupiterTriggerWithdrawal: Identifiable {
  let order: JupiterTriggerOrder
  let plan: JupiterTriggerWithdrawalPlan
  let wallet: TradingWallet
  let account: WalletAccount

  var id: String { plan.planId }
  var requestID: String { Self.requestPrefix(for: order) + plan.planId }

  private static func requestPrefix(for order: JupiterTriggerOrder) -> String {
    "withdraw:\(order.id):"
  }

  static func pending(order: JupiterTriggerOrder, account: WalletAccount, entries: [WalletTradeActivity]) -> Bool {
    entries.contains {
      $0.address == account.address && $0.details.provider == .jupiterTrigger
        && $0.details.requestID.hasPrefix(requestPrefix(for: order)) && $0.status == .pending
    }
  }
}

struct JupiterTriggerWithdrawalReview: View {
  let withdrawal: JupiterTriggerWithdrawal
  let walletStore: WalletStore

  @Environment(\.dismiss) private var dismiss
  @State private var submitted: WalletTradeActivity?
  @State private var submitting = false
  @State private var error: String?

  private var plan: JupiterTriggerWithdrawalPlan { withdrawal.plan }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { clock in
      VStack(alignment: .leading, spacing: 14) {
        Text("Withdraw from Jupiter").font(AppTypography.title2Semibold)
        if let submitted {
          let latest = walletStore.trades.entries.first { $0.id == submitted.id } ?? submitted
          LabeledContent("Status", value: latest.status.label)
          if latest.status == .pending {
            Text("Check Wallet Activity for confirmation before trying again.")
              .foregroundStyle(.secondary)
          }
          Text(verbatim: submitted.transactionID).monospaced().font(AppTypography.caption)
            .textSelection(.enabled)
        } else {
          withdrawalDetails
          if clock.date >= plan.signingPlan.expiry {
            Text("Review expired. Reopen the withdrawal from Orders.")
              .foregroundStyle(.orange)
          }
        }
        if let error { Text(error).foregroundStyle(.orange) }
        HStack {
          Spacer()
          Button(submitted == nil ? "Close" : "Done") { dismiss() }
            .keyboardShortcut(.cancelAction).disabled(submitting)
          if submitted == nil {
            Button(submitting ? "Submitting…" : "Confirm withdrawal") { confirm() }
              .buttonStyle(.borderedProminent)
              .disabled(submitting || walletStore.submitting || clock.date >= plan.signingPlan.expiry)
          }
        }
      }
      .font(AppTypography.callout)
      .padding(20).frame(width: 460)
    }
    .interactiveDismissDisabled(submitting)
  }

  private var withdrawalDetails: some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent("Return to", value: withdrawal.wallet.label)
      line("Wallet address", withdrawal.account.address)
      line("Vault address", plan.signingPlan.vault)
      line("Token mint", plan.signingPlan.mint)
      LabeledContent("Amount", value: JupiterTriggerOrder.formattedAmount(
        plan.signingPlan.amount, mint: plan.signingPlan.mint, decimals: plan.mintDecimals))
      LabeledContent("Network fee", value: "\(JupiterSwapPlan.units(plan.feeLamports, decimals: 9)) SOL")
      if plan.rentLamports != "0" {
        LabeledContent("Token account rent", value: "\(JupiterSwapPlan.units(plan.rentLamports, decimals: 9)) SOL")
      }
    }
  }

  private func line(_ title: String, _ value: String) -> some View {
    LabeledContent(title) {
      Text(verbatim: value).monospaced().font(AppTypography.caption).textSelection(.enabled)
    }
  }

  private func confirm() {
    guard !submitting, plan.signingPlan.expiry > .now else { return }
    submitting = true
    error = nil
    Task {
      defer { submitting = false }
      do {
        try await walletStore.unlock()
        submitted = try await walletStore.performTradeStep(
          operation: .jupiterTriggerTransfer, plan: plan.signingPlan, wallet: withdrawal.wallet,
          account: withdrawal.account, activity: WalletTradeDetails(
            provider: .jupiterTrigger, title: "Withdraw from Jupiter", chain: "solana",
            requestID: withdrawal.requestID, expiresAt: plan.signingPlan.expiry,
            lastValidBlockHeight: plan.lastValidBlockHeight)
        ) { signed in
          try await JupiterTriggerManagementClient().submit(signed, order: withdrawal.order, review: plan)
        }
      } catch is CancellationError {
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}
