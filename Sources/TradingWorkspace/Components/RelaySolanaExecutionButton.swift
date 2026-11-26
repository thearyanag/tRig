import SwiftUI

struct RelaySolanaExecutionButton: View {
  let request: ExecutionQuoteRequest
  let wallet: TradingWallet
  let account: WalletAccount
  let quote: ExecutionQuote

  @Environment(WalletStore.self) private var store
  @State private var plan: Plan?
  @State private var showReview = false
  @State private var preparing = false
  @State private var confirming = false
  @State private var error: String?
  @State private var reviewError: String?
  @State private var submitted: WalletTradeActivity?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(preparing ? "Preparing deposit…" : "Review bridge") {
        Task { await prepare() }
      }
      .buttonStyle(.borderedProminent)
      .disabled(preparing || store.submitting || submitted != nil)
      if let error {
        Text(error).font(AppTypography.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let submitted {
        Text(submitted.status == .pending ? "Track this bridge in Markets Activity." : submitted.status.label)
          .font(AppTypography.caption).foregroundStyle(.secondary)
      }
    }
    .sheet(isPresented: $showReview, onDismiss: { plan = nil; reviewError = nil }) {
      if let plan { review(plan) }
    }
  }

  private func review(_ plan: Plan) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Review Relay bridge").font(AppTypography.title2Semibold)
      VStack(alignment: .leading, spacing: 9) {
        LabeledContent("Funding wallet", value: "\(wallet.label) · \(account.shortAddress)")
        LabeledContent("Pay on Solana", value: "\(plan.quote.payAmount) \(plan.quote.input.symbol)")
        LabeledContent("Estimated receive", value: "\(plan.quote.receiveAmount) \(plan.quote.output.symbol)")
        LabeledContent("Minimum receive", value: "\(plan.quote.minimumReceive ?? "—") \(plan.quote.output.symbol)")
        LabeledContent("Destination network", value: plan.destination)
        LabeledContent("Recipient") {
          Text(verbatim: plan.recipient).textSelection(.enabled).monospaced()
            .font(AppTypography.caption)
        }
        LabeledContent("Solana network fee", value: "\(plan.originFee) SOL")
      }
      .font(AppTypography.callout)
      if let reviewError {
        Text(reviewError).font(AppTypography.callout).foregroundStyle(.orange)
      }
      Divider()
      TimelineView(.periodic(from: .now, by: 1)) { context in
        HStack {
          let expired = context.date >= plan.expiry
          Button("Back") { showReview = false }
            .keyboardShortcut(.cancelAction).disabled(confirming)
          Spacer()
          if expired {
            Text("Review expired").foregroundStyle(.orange).font(AppTypography.caption)
          }
          Button(confirming ? "Submitting…" : "Confirm bridge") {
            Task { await confirm(plan) }
          }
          .buttonStyle(.borderedProminent)
          .disabled(expired || confirming || store.submitting || store.authorizing)
        }
      }
    }
    .padding(20)
    .frame(width: 420)
    .interactiveDismissDisabled(confirming)
    .background(TerminalStyle.canvas)
  }

  private func prepare() async {
    guard !preparing, account.family == .solana, request.input.chain == "solana",
      quote.matches(request), quote.isFresh(at: .now), let minimum = quote.minimumReceive,
      request.context.sender == account.address
    else {
      error = "Refresh the quote for the selected Solana wallet."
      return
    }
    preparing = true
    error = nil
    defer { preparing = false }
    var boundRequest = request
    boundRequest.provider = .relay
    do {
      let body = try JSONEncoder().encode(Prepare(quote: boundRequest, minimumReceive: minimum))
      let data = try await LocalBackendClient.post("api/wallet/trade/relay/solana/prepare", body: body)
      let prepared = try JSONDecoder().decode(Plan.self, from: data)
      guard prepared.quote.matches(boundRequest), prepared.terms.wallet == account.address,
        prepared.terms.inputMint == boundRequest.input.address, prepared.expiry > .now,
        prepared.recipient == boundRequest.context.recipient
      else { throw WalletFailure("The deposit does not match the selected terms.") }
      plan = prepared
      showReview = true
    } catch is CancellationError {
      return
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func confirm(_ plan: Plan) async {
    guard !confirming, plan.expiry > .now else { return }
    confirming = true
    reviewError = nil
    defer { confirming = false }
    do {
      try await store.unlock()
      submitted = try await store.performTradeStep(
        operation: .relaySolana, plan: plan.signing, wallet: wallet, account: account,
        activity: WalletTradeDetails(
          provider: .relay,
          title: "Bridge \(plan.quote.payAmount) \(plan.quote.input.symbol) to \(plan.destination)",
          chain: "solana", requestID: plan.requestId, expiresAt: plan.expiry,
          lastValidBlockHeight: plan.lastValidBlockHeight
        )
      ) { signed in
        let body = try JSONEncoder().encode(Submit(
          requestId: plan.requestId, signed: signed.signed, transactionId: signed.transactionId))
        let data = try await LocalBackendClient.post("api/wallet/trade/relay/solana/submit", body: body)
        return try JSONDecoder().decode(Status.self, from: data).status
      }
      showReview = false
    } catch is CancellationError {
      return
    } catch {
      reviewError = error.localizedDescription
    }
  }

  private struct Prepare: Encodable {
    let quote: ExecutionQuoteRequest
    let minimumReceive: String
  }

  private struct Plan: Decodable, Sendable {
    struct Terms: Codable, Sendable {
      let wallet: String
      let inputMint: String
      let inputAtomic: String
      let orderId: [UInt8]
      let expiresAt: UInt64
    }

    struct Signing: Encodable, Sendable {
      let transaction: String
      let terms: Terms
    }

    let requestId: String
    let transaction: String
    let terms: Terms
    let originFee: String
    let recipient: String
    let destination: String
    let lastValidBlockHeight: UInt64
    let quote: ExecutionQuote

    var expiry: Date { Date(timeIntervalSince1970: Double(terms.expiresAt)) }
    var signing: Signing { Signing(transaction: transaction, terms: terms) }
  }

  private struct Submit: Encodable {
    let requestId: String
    let signed: String
    let transactionId: String
  }

  private struct Status: Decodable {
    let status: WalletTradeStatus
  }
}
