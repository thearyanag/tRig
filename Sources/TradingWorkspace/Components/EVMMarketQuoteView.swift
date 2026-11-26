import SwiftUI

/// Native quote ticket for chain-aware token pairs.
struct EVMMarketQuoteView: View {
  let asset: Asset
  @Binding var trade: TradeDraft
  let openRoutes: () -> Void
  @Environment(WalletStore.self) private var walletStore: WalletStore?
  @Environment(PortfolioStore.self) private var portfolio: PortfolioStore?
  @State private var fundingWalletID: UUID?
  @State private var fundFromWallet = true
  @State private var counterAsset: Asset?
  @State private var showPicker = false
  @State private var sender = ""
  @State private var recipient = ""
  @State private var store = ExecutionQuoteStore()
  @State private var details = false
  @FocusState private var amountFocused: Bool
  private var fieldRadius: CGFloat {
    if #available(macOS 26, *) { return TerminalStyle.quoteFieldRadius }
    return 0
  }
  private var counter: Asset? { counterAsset ?? asset.settlementAsset }
  private var inputAsset: Asset? { trade.side == .buy ? counter : asset }
  private var outputAsset: Asset? { trade.side == .buy ? asset : counter }
  private var crossChain: Bool { inputAsset?.chainID != outputAsset?.chainID }
  private var fundingFamily: WalletFamily { inputAsset?.chainID == "solana" ? .solana : .evm }
  private var funding: (wallet: TradingWallet, account: WalletAccount)? {
    guard fundFromWallet else { return nil }
    return walletStore?.funding(walletID: fundingWalletID, family: fundingFamily)
  }
  private var destinationAddress: String? {
    guard crossChain, let funding else { return nil }
    let family: WalletFamily = outputAsset?.chainID == "solana" ? .solana : .evm
    return funding.wallet.accounts.first { $0.family == family }?.address
  }
  private var request: ExecutionQuoteRequest {
    ExecutionQuoteRequest(
      provider: funding == nil ? nil : .relay, side: trade.side.rawValue.lowercased(),
      input: .init(chain: inputAsset?.chainID ?? "", address: inputAsset?.id ?? ""),
      output: .init(chain: outputAsset?.chainID ?? "", address: outputAsset?.id ?? ""),
      amount: trade.quoteAmount, orderType: .market,
      slippageBps: trade.slippage.basisPoints,
      context: .init(
        sender: funding?.account.address ?? (sender.isEmpty ? nil : sender),
        recipient: recipient.isEmpty ? destinationAddress : recipient))
  }
  private var validContext: Bool {
    Asset.validAddress(request.context.sender ?? "", chain: request.input.chain)
      && (!crossChain || Asset.validAddress(request.context.recipient ?? "", chain: request.output.chain))
  }
  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { clock in
      let quote = store.visible(for: request)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("Pay").font(AppTypography.caption).foregroundStyle(.secondary)
          HStack(spacing: 8) {
            token(inputAsset, selectable: trade.side == .buy)
            TextField("0.00", text: $trade.amountText).textFieldStyle(.plain)
              .multilineTextAlignment(.trailing).font(AppTypography.font(size: 18, weight: .medium))
              .focused($amountFocused).accessibilityLabel(
                "Quote amount in \(inputAsset?.symbol ?? "pay token")")
          }.padding(10).background(TerminalStyle.field, in: RoundedRectangle(cornerRadius: fieldRadius))
          if let funding, let inputAsset, let balance = portfolio?.walletBalance(
            chain: inputAsset.chainID, mint: inputAsset.id, account: funding.account)
          {
            row("Wallet balance", "\(PortfolioFormat.quantity(balance)) \(inputAsset.symbol)")
          }
          Text("Receive estimate").font(AppTypography.caption).foregroundStyle(.secondary)
          HStack {
            token(outputAsset, selectable: trade.side == .sell)
            Spacer(minLength: 0)
            Text(quote.map { PortfolioFormat.quantity($0.receiveAmount) } ?? "—")
              .font(AppTypography.font(size: 17, weight: .medium)).monospacedDigit().lineLimit(1)
              .minimumScaleFactor(0.6)
          }.padding(10).background(TerminalStyle.field, in: RoundedRectangle(cornerRadius: fieldRadius))
          if crossChain {
            Label(
              "\(inputAsset?.network ?? "") → \(outputAsset?.network ?? "")",
              systemImage: "arrow.left.arrow.right"
            )
            .font(AppTypography.caption).foregroundStyle(.secondary)
          }
          VStack(alignment: .leading, spacing: 5) {
            if let walletStore, walletStore.wallets.contains(where: { wallet in
              wallet.accounts.contains { $0.family == fundingFamily }
            }) {
              Toggle("Fund from tRig wallet", isOn: $fundFromWallet)
                .toggleStyle(.switch).controlSize(.small).font(AppTypography.caption)
            }
            if let walletStore, funding != nil {
              WalletFundingPicker(family: fundingFamily, selection: $fundingWalletID)
                .environment(walletStore)
            } else {
              Text("Public sender address").foregroundStyle(.secondary)
              TextField("Address on \(inputAsset?.network ?? asset.network)", text: $sender)
                .textFieldStyle(.plain).padding(8)
                .background(TerminalStyle.field, in: RoundedRectangle(cornerRadius: fieldRadius))
                .accessibilityLabel("Public sender address for quote")
            }
            if crossChain {
              Text("Destination address").foregroundStyle(.secondary)
              TextField(destinationAddress ?? "Address on \(outputAsset?.network ?? asset.network)", text: $recipient)
                .textFieldStyle(.plain).padding(8)
                .background(TerminalStyle.field, in: RoundedRectangle(cornerRadius: fieldRadius))
                .accessibilityLabel("Public destination address for quote")
            }
          }
          Picker("Slippage", selection: $trade.slippage) {
            ForEach(SlippagePreset.allCases) { Text($0.rawValue).tag($0) }
          }.pickerStyle(.segmented).font(AppTypography.caption)
          if let quote {
            row(
              "Minimum receive",
              quote.minimumReceive.map { "\(PortfolioFormat.quantity($0)) \(quote.output.symbol)" }
                ?? "Not supplied")
            Text(
              quote.isFresh(at: clock.date)
                ? "Updated \(max(0, Int(clock.date.timeIntervalSince1970 - quote.fetchedAt)))s ago"
                : "Quote is stale · refresh"
            )
            .font(AppTypography.caption).foregroundStyle(
              quote.isFresh(at: clock.date) ? Color.secondary : .orange)
            DisclosureGroup("Quote details", isExpanded: $details) {
              VStack(alignment: .leading, spacing: 6) {
                row("Route", quote.providerName)
                ForEach(Array(quote.fees.enumerated()), id: \.offset) { _, fee in
                  row(
                    fee.kind,
                    fee.amountUsd.map { PortfolioFormat.currency($0) }
                      ?? fee.rateBps.map {
                        DisplayFormat.number(Decimal($0) / 100, decimals: 2) + "%"
                      } ?? "Not supplied")
                }
                ForEach(quote.warnings, id: \.self) { Text($0).foregroundStyle(.secondary) }
              }.font(AppTypography.caption).padding(.top, 8)
            }.font(AppTypography.caption)
          }
          if let error = store.error {
            Text(error).font(AppTypography.caption).foregroundStyle(.orange).fixedSize(
              horizontal: false, vertical: true)
          }
          Button("Cross-chain & advanced…", action: openRoutes)
            .buttonStyle(.link).font(AppTypography.caption)
        }.padding(12)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          Button {
            amountFocused = false
            store.load(request)
          } label: {
            Text(store.isLoading ? "Getting quote…" : "Get quote")
              .font(AppTypography.bodySemibold).frame(maxWidth: .infinity).frame(height: 40)
          }.buttonStyle(TerminalControlStyle.primary)
          .disabled(
            !request.isValid || !validContext || store.isLoading || asset.marketQuotes == false)
          if let quote, quote.provider == .relay, let funding, let walletStore {
            if fundingFamily == .evm {
              RelayExecutionButton(request: request, wallet: funding.wallet, account: funding.account,
                quote: quote).environment(walletStore).id(quote.id)
            } else {
              RelaySolanaExecutionButton(request: request, wallet: funding.wallet, account: funding.account,
                quote: quote).environment(walletStore).id(quote.id)
            }
          } else if asset.marketQuotes == false {
            Text("Market quotes are unavailable on this network.")
              .font(AppTypography.caption).foregroundStyle(.secondary)
          }
        }.padding(12).background(TerminalStyle.quotePanel).overlay(alignment: .top) { Divider() }
      }
    }
    .font(AppTypography.body)
    .onChange(of: request) { _, value in store.requestDidChange(value) }
    .onChange(of: request.input.chain) { _, _ in
      sender = ""
      fundingWalletID = nil
    }
    .onChange(of: request.output.chain) { _, _ in recipient = "" }
    .onDisappear { store.clear() }
    .sheet(isPresented: $showPicker) {
      AssetSearchView(
        workspace: WorkspaceStore.shared, initialChain: asset.chainID,
        onSelect: { selected in
          counterAsset = selected
          if trade.side == .buy { trade.amountText = "" }
        })
    }
  }
  @ViewBuilder private func token(_ token: Asset?, selectable: Bool) -> some View {
    Button {
      showPicker = true
    } label: {
      HStack(spacing: 6) {
        if let token { AssetIconView(asset: token, size: 20) }
        VStack(alignment: .leading, spacing: 2) {
          Text(token?.symbol ?? "Choose token").font(AppTypography.calloutMedium)
          if let token {
            Text(token.network).font(AppTypography.font(size: 10)).foregroundStyle(.secondary)
          }
        }
        if selectable { Image(systemName: "chevron.down").font(.system(size: 8)) }
      }
    }.buttonStyle(.plain).disabled(!selectable)
      .accessibilityLabel(
        selectable ? "Choose quote token" : "Selected \(token?.symbol ?? "token")")
  }
  private func row(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(value).monospacedDigit().multilineTextAlignment(.trailing)
    }.font(AppTypography.caption)
  }
}
