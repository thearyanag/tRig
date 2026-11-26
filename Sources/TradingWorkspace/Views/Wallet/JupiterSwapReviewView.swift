import SwiftUI

struct JupiterSwapReviewView: View {
  let quote: SwapQuote
  let wallet: TradingWallet
  let account: WalletAccount

  @Environment(WalletStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var plan: JupiterSwapPlan?
  @State private var receipt: WalletTradeActivity?
  @State private var error: String?
  @State private var busy = false
  @State private var reviewID = UUID()

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      VStack(alignment: .leading, spacing: 16) {
        Text(receipt == nil ? "Review swap" : "Swap activity").font(AppTypography.title2Semibold)
        row("Funding wallet", "\(wallet.label) · \(account.shortAddress)")
        if let receipt {
          receiptDetails(store.trades.entries.first { $0.id == receipt.id } ?? receipt)
        } else if let plan {
          row("You pay", "\(quote.payAmount) \(quote.paySymbol)")
          row("Available", "\(units(plan.inputBalance, quote.inputDecimals)) \(quote.paySymbol)")
          row("Estimated receive", "\(units(plan.outAmount, quote.outputDecimals)) \(quote.receiveSymbol)")
          row("Minimum receive", "\(units(plan.terms.minimumOut, quote.outputDecimals)) \(quote.receiveSymbol)")
          row("Jupiter fee", "\(DisplayFormat.number(Decimal(plan.feeBps) / 100, decimals: 2))%")
          row("Maximum network cost", "\(units(plan.terms.maxNetworkCost, 9)) SOL")
          if plan.wrappedSolReturned != "0" {
            row("Existing WSOL and rent returned", "\(units(plan.wrappedSolReturned, 9)) SOL")
          }
          if plan.expiry <= context.date {
            Text("Swap review expired. Refresh for current terms.")
              .font(AppTypography.callout).foregroundStyle(.orange)
          }
        } else if busy {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking balances and simulating the swap…").foregroundStyle(.secondary)
          }
        }
        if let error {
          Text(error).font(AppTypography.callout)
            .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        HStack {
          Button(receipt == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
          Spacer()
          if receipt == nil {
            if let plan, plan.expiry > context.date {
              Button(store.isUnlocked ? "Confirm swap" : "Unlock wallet") {
                if store.isUnlocked { confirm(plan) }
                else { unlock() }
              }.buttonStyle(.borderedProminent).disabled(busy || store.submitting)
            } else if !busy {
              Button("Refresh review") { reviewID = UUID() }.buttonStyle(.borderedProminent)
            }
          }
        }.disabled(store.submitting)
      }.padding(28).frame(width: 460)
    }
    .font(AppTypography.body)
    .task(id: reviewID) { await prepare() }
    .interactiveDismissDisabled(store.submitting)
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(verbatim: value).monospacedDigit().multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
  }

  private func units(_ value: String, _ decimals: Int) -> String {
    JupiterSwapPlan.units(value, decimals: decimals)
  }

  private func receiptDetails(_ receipt: WalletTradeActivity) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      row("Status", receipt.status.label)
      Text(verbatim: receipt.transactionID)
        .font(AppTypography.caption).monospaced().textSelection(.enabled)
      if receipt.status == .pending {
        Text("Track confirmation in Wallet Activity. Check the status before sending again.")
          .font(AppTypography.callout).foregroundStyle(.secondary)
      }
    }
  }

  private func prepare() async {
    busy = true
    error = nil
    plan = nil
    defer { busy = false }
    do { plan = try await JupiterSwapClient().prepare(quote: quote, account: account) }
    catch is CancellationError {}
    catch { self.error = error.localizedDescription }
  }

  private func unlock() {
    busy = true
    error = nil
    Task {
      defer { busy = false }
      do { try await store.unlock() }
      catch is CancellationError {}
      catch { self.error = error.localizedDescription }
    }
  }

  private func confirm(_ plan: JupiterSwapPlan) {
    busy = true
    error = nil
    Task {
      defer { busy = false }
      do {
        guard plan.matches(quote: quote, account: account) else {
          throw WalletFailure("Refresh this review before trading.")
        }
        receipt = try await store.performTradeStep(
          operation: .jupiterSwap, plan: plan.signingPayload, wallet: wallet, account: account,
          activity: WalletTradeDetails(
            provider: .jupiter, title: "\(quote.paySymbol) → \(quote.receiveSymbol)", chain: "solana",
            requestID: plan.requestId, expiresAt: plan.expiry,
            lastValidBlockHeight: plan.lastValidBlockHeight)
        ) { signed in
          try await JupiterSwapClient().submit(signed, for: plan)
        }
      } catch is CancellationError {}
      catch { self.error = error.localizedDescription }
    }
  }
}
