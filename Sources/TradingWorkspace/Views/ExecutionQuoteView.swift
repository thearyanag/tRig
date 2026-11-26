import SwiftUI

struct ExecutionQuoteView: View {
  let asset: Asset
  @Environment(\.dismiss) private var dismiss
  @Environment(WalletStore.self) private var walletStore: WalletStore?
  @Environment(PortfolioStore.self) private var portfolio: PortfolioStore?
  @State private var store = ExecutionQuoteStore()
  @State private var providerStore = ExecutionProviderStore()
  @State private var provider = "auto"
  @State private var quoteSide = "buy"
  @State private var orderType = ExecutionOrderType.market
  @State private var fromChain = "solana"
  @State private var toChain = "solana"
  @State private var fromAddress = SwapQuoteInput.usdc
  @State private var toAddress = ""
  @State private var amount = "100"
  @State private var price = ""
  @State private var slippage = SlippagePreset.standard
  @State private var showAddressContext = false
  @State private var sender = ""
  @State private var recipient = ""
  @State private var fundingWalletID: UUID?
  @State private var fundFromWallet = true
  @State private var fromToken: Asset?
  @State private var toToken: Asset?
  @State private var pickingToken: String?
  init(
    asset: Asset, initialOrderType: ExecutionOrderType, initialSide: TradeSide = .buy,
    initialAmount: String = "100"
  ) {
    self.asset = asset
    let selling = initialOrderType == .stopLoss || initialSide == .sell
    _quoteSide = State(initialValue: selling ? "sell" : "buy")
    _orderType = State(initialValue: initialOrderType)
    _provider = State(initialValue: initialOrderType == .market ? "auto" : "flash")
    _fromChain = State(initialValue: asset.chainID)
    _toChain = State(initialValue: asset.chainID)
    _fromAddress = State(initialValue: selling ? asset.id : asset.settlement?.address ?? "")
    _toAddress = State(initialValue: selling ? asset.settlement?.address ?? "" : asset.id)
    _amount = State(initialValue: initialAmount)
    let counter = asset.settlementAsset
    _fromToken = State(initialValue: selling ? asset : counter)
    _toToken = State(initialValue: selling ? counter : asset)
  }
  private var selectedProvider: ExecutionProvider? { ExecutionProvider(rawValue: provider) }
  private var selectedInfo: ExecutionProviderInfo? {
    providerStore.providers.first { $0.id == selectedProvider }
  }
  private var availableOrderTypes: [ExecutionOrderType] {
    selectedInfo?.orderTypes ?? ExecutionOrderType.allCases
  }
  private var supportsWalletRoute: Bool {
    orderType == .market
      && (selectedProvider == nil || selectedProvider == .relay)
      && (fromChain.hasPrefix("eip155:") || (fromChain == "solana" && fromChain != toChain))
      && (toChain == "solana" || toChain.hasPrefix("eip155:"))
  }

  private var fundingFamily: WalletFamily { fromChain == "solana" ? .solana : .evm }

  private var funding: (wallet: TradingWallet, account: WalletAccount)? {
    guard supportsWalletRoute, fundFromWallet else { return nil }
    return walletStore?.funding(walletID: fundingWalletID, family: fundingFamily)
  }

  private var walletRecipient: String? {
    let family: WalletFamily = toChain == "solana" ? .solana : .evm
    return funding?.wallet.accounts.first { $0.family == family }?.address
  }

  private var hasWalletDestination: Bool {
    guard funding != nil else { return true }
    return request.context.recipient.map { Asset.validAddress($0, chain: toChain) } ?? false
  }

  private var request: ExecutionQuoteRequest {
    let enteredRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    return ExecutionQuoteRequest(
      provider: funding == nil ? selectedProvider : .relay,
      side: orderType == .stopLoss ? "sell" : quoteSide,
      input: ExecutionTokenRef(
        chain: fromChain, address: fromAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
      output: ExecutionTokenRef(
        chain: toChain, address: toAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
      amount: amount.trimmingCharacters(in: .whitespacesAndNewlines), orderType: orderType,
      slippageBps: slippage.basisPoints,
      limitPriceUsd: orderType == .limit ? price : nil,
      triggerPriceUsd: orderType == .stopLoss ? price : nil,
      context: ExecutionQuoteContext(
        sender: funding?.account.address ?? (sender.isEmpty ? nil : sender),
        recipient: enteredRecipient.isEmpty ? walletRecipient : enteredRecipient))
  }
  private var chains: [ExecutionChain] {
    let infos = selectedInfo.map { [$0] } ?? providerStore.providers
    var unique: [String: ExecutionChain] = [:]
    for chain in infos.flatMap(\.chains) where chain.enabled {
      unique[chain.id] = chain
    }
    return unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(orderType == .market ? "Swap routes" : "Order estimates")
          .font(AppTypography.font(size: 20, weight: .semibold))
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
          .disabled(walletStore?.submitting == true)
      }.padding(20)
      Divider()
      HStack(alignment: .top, spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Picker("Route", selection: $provider) {
              Text("Automatic").tag("auto")
              ForEach(ExecutionProvider.allCases) { value in
                let info = providerStore.providers.first { $0.id == value }
                Text(value.name + (info?.configured == false ? " · Not configured" : "")).tag(
                  value.rawValue)
              }
            }
            Picker("Order type", selection: $orderType) {
              ForEach(availableOrderTypes) { Text($0.name).tag($0) }
            }
            if let info = selectedInfo, !info.configured {
              Text("Access to \(info.name) is not configured on this Mac.").font(
                AppTypography.callout
              ).foregroundStyle(.orange)
            }
            tokenFields("From", chain: $fromChain, address: $fromAddress)
            tokenFields("To", chain: $toChain, address: $toAddress)
            field("Amount to spend", text: $amount, placeholder: "0.00")
            if orderType == .limit {
              Picker("Limit direction", selection: $quoteSide) {
                Text("Buy").tag("buy")
                Text("Sell").tag("sell")
              }.pickerStyle(.segmented)
            }
            if orderType != .market {
              field(
                orderType == .limit
                  ? (quoteSide == "buy"
                    ? "USD limit price · receive token" : "USD limit price · token being sold")
                  : "USD stop price · token being sold",
                text: $price, placeholder: "0.00")
              if fromChain != toChain {
                Text("Conditional quotes require both tokens on the same chain.").font(
                  AppTypography.caption
                ).foregroundStyle(.orange)
              }
            }
            Picker("Slippage", selection: $slippage) {
              ForEach(SlippagePreset.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            addressFields
            if providerStore.isLoading { ProgressView().controlSize(.small) }
            if let error = providerStore.error {
              Text(error).font(AppTypography.caption).foregroundStyle(.orange)
            }
            Button("Refresh available routes") { Task { await providerStore.load() } }.font(
              AppTypography.caption
            ).buttonStyle(.plain).foregroundStyle(.blue)
          }.padding(20).disabled(walletStore?.submitting == true)
        }.frame(width: 350)
        Divider()
        TimelineView(.periodic(from: .now, by: 1)) { context in
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              if let quote = store.visible(for: request) {
                quoteDetails(quote, at: context.date)
                walletExecution(quote)
              } else {
                Image(systemName: "arrow.left.arrow.right").font(.title2).foregroundStyle(
                  .secondary)
                Text("Estimate a route").font(AppTypography.bodySemibold)
                Text(
                  "Choose networks and assets to see the estimated amount and fees."
                )
                .font(AppTypography.callout).foregroundStyle(.secondary)
              }
              if let error = store.error {
                Text(error).font(AppTypography.callout).foregroundStyle(.orange).fixedSize(
                  horizontal: false, vertical: true)
              }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      Divider()
      HStack {
        if store.isLoading { ProgressView().controlSize(.small) }
        Spacer()
        Button(store.isLoading ? "Getting quote…" : "Get quote") { store.load(request) }
          .buttonStyle(.borderedProminent).disabled(
            !request.isValid || !hasWalletDestination || store.isLoading || selectedInfo?.configured == false
              || walletStore?.submitting == true)
      }.padding(20)
    }
    .frame(width: 780, height: 670).background(TerminalStyle.canvas).preferredColorScheme(.dark)
    .font(AppTypography.body)
    .task { await providerStore.load() }
    .onChange(of: request) { _, value in store.requestDidChange(value) }
    .onChange(of: availableOrderTypes) { _, values in
      if !values.contains(orderType) { orderType = values.first ?? .market }
    }
    .onChange(of: provider) { _, _ in
      if !availableOrderTypes.contains(orderType) {
        orderType = availableOrderTypes.first ?? .market
      }
      if provider == "relay" || fromChain != toChain { showAddressContext = true }
      let available = chains.map(\.id)
      if !available.isEmpty {
        if !available.contains(fromChain) {
          fromChain = available[0]
          fromAddress = ""
        }
        if !available.contains(toChain) {
          toChain = available[0]
          toAddress = ""
        }
      }
    }
    .onChange(of: fromChain) { old, value in
      if old != value {
        fundingWalletID = nil
        if value != toChain { showAddressContext = true }
        if fromToken?.chainID != value || fromToken?.id != fromAddress {
          fromAddress = ""
          fromToken = nil
        }
        amount = ""
      }
    }
    .onChange(of: toChain) { old, value in
      if old != value {
        recipient = ""
        if value != fromChain { showAddressContext = true }
        if toToken?.chainID != value || toToken?.id != toAddress {
          toAddress = ""
          toToken = nil
        }
      }
    }
    .onChange(of: orderType) { _, value in
      price = ""
      if value == .stopLoss { quoteSide = "sell" }
      if value != .market { provider = ExecutionProvider.flash.rawValue }
    }
    .onChange(of: quoteSide) { old, value in
      if old != value {
        swap(&fromChain, &toChain)
        swap(&fromAddress, &toAddress)
        swap(&fromToken, &toToken)
        amount = ""
        price = ""
      }
    }
    .onDisappear { store.clear() }
    .sheet(
      isPresented: Binding(get: { pickingToken != nil }, set: { if !$0 { pickingToken = nil } })
    ) {
      let side = pickingToken ?? "From"
      AssetSearchView(
        workspace: WorkspaceStore.shared,
        initialChain: side == "From" ? fromChain : toChain,
        onSelect: { token in select(token, side: side) })
    }
  }

  private func select(_ token: Asset, side: String) {
    if side == "From" {
      fromToken = token
      fromChain = token.chainID
      fromAddress = token.id
      amount = ""
    } else {
      toToken = token
      toChain = token.chainID
      toAddress = token.id
    }
  }

  @ViewBuilder private func nativeTokenPicker(side: String) -> some View {
    let networks = providerStore.providers.first { $0.id == .relay }?.chains ?? []
    if orderType == .market, selectedProvider == nil || selectedProvider == .relay,
      networks.contains(where: { $0.enabled && $0.nativeToken != nil }) {
      Menu("Native tokens") {
        ForEach(networks.filter(\.enabled)) { network in
          if let native = network.nativeToken {
            Button("\(native.symbol) · \(network.name)") {
              select(Asset(id: native.address, name: native.symbol, symbol: native.symbol,
                network: network.name, pool: "", decimals: native.decimals, priceUsd: nil,
                chainId: network.id), side: side)
              provider = ExecutionProvider.relay.rawValue
            }
          }
        }
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("Choose native \(side.lowercased()) token")
    }
  }

  private func tokenFields(_ label: String, chain: Binding<String>, address: Binding<String>)
    -> some View
  {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(label).font(AppTypography.calloutMedium)
        Spacer()
        nativeTokenPicker(side: label)
      }
      let token = label == "From" ? fromToken : toToken
      Button {
        pickingToken = label
      } label: {
        HStack(spacing: 8) {
          if let token { AssetIconView(asset: token, size: 24) }
          VStack(alignment: .leading, spacing: 3) {
            Text(token?.symbol ?? "Choose token").font(AppTypography.calloutMedium)
            Text(token?.network ?? PortfolioFormat.chainName(chain.wrappedValue))
              .font(AppTypography.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Image(systemName: "chevron.down").font(.caption)
        }.padding(10).background(TerminalStyle.field)
      }.buttonStyle(.plain).accessibilityLabel("Choose \(label.lowercased()) token and network")
      if !address.wrappedValue.isEmpty {
        Text("\(address.wrappedValue.prefix(6))…\(address.wrappedValue.suffix(4))")
          .font(AppTypography.caption).foregroundStyle(.secondary)
      }
    }
  }
  private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label).font(AppTypography.caption).foregroundStyle(.secondary)
      TextField(placeholder, text: text).textFieldStyle(.roundedBorder).accessibilityLabel(label)
    }
  }
  @ViewBuilder private var addressFields: some View {
    if supportsWalletRoute, walletStore?.funding(walletID: nil, family: fundingFamily) != nil {
      Toggle("Fund from tRig wallet", isOn: $fundFromWallet)
        .toggleStyle(.switch).controlSize(.small)
    }
    if let funding {
      WalletFundingPicker(family: fundingFamily, selection: $fundingWalletID)
      if let fromToken, let balance = portfolio?.walletBalance(
        chain: fromChain, mint: fromAddress, account: funding.account) {
        Text("Available \(balance) \(fromToken.symbol)")
          .font(AppTypography.caption).foregroundStyle(.secondary)
      }
      field("Destination address", text: $recipient,
        placeholder: walletRecipient ?? "Enter a destination address")
    } else {
      DisclosureGroup("Address context", isExpanded: $showAddressContext) {
        VStack(alignment: .leading, spacing: 10) {
          field("Public sender address", text: $sender,
            placeholder: "Required for Relay / cross-chain estimates")
          field("Public destination address", text: $recipient,
            placeholder: "Required for cross-chain estimates")
        }.padding(.top, 8)
      }
    }
  }

  @ViewBuilder private func quoteDetails(_ quote: ExecutionQuote, at date: Date) -> some View {
    Text(quote.providerName).font(AppTypography.font(size: 17, weight: .semibold))
    Text(quote.orderType == .market ? "Indicative swap quote" : "\(quote.orderType.name) estimate")
      .font(AppTypography.callout).foregroundStyle(.secondary)
    row("Pay", "\(quote.payAmount) \(quote.input.symbol)")
    row("Receive estimate", "\(quote.receiveAmount) \(quote.output.symbol)")
    row("Minimum receive",
      quote.minimumReceive.map { "\($0) \(quote.output.symbol)" } ?? "Not supplied")
    if let impact = PortfolioFormat.percent(quote.priceImpactPercent) {
      row("Price impact", impact)
    }
    Divider()
    Text("Fees included in the estimate").font(AppTypography.calloutMedium)
    ForEach(Array(quote.fees.enumerated()), id: \.offset) { _, fee in
      row(
        fee.kind,
        fee.amountUsd.map { PortfolioFormat.currency($0) }
          ?? fee.rateBps.map { DisplayFormat.number(Decimal($0) / 100, decimals: 2) + "%" }
          ?? "Not supplied")
    }
    let fresh = quote.isFresh(at: date)
    Text(fresh ? "Updated \(max(0, Int(date.timeIntervalSince1970 - quote.fetchedAt)))s ago"
      : "Estimate is stale · refresh")
      .font(AppTypography.caption).foregroundStyle(fresh ? Color.secondary : .orange)
    ForEach(quote.warnings, id: \.self) {
      Text($0).font(AppTypography.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private func walletExecution(_ quote: ExecutionQuote) -> some View {
    if quote.provider == .relay, let funding {
      if fundingFamily == .evm {
        RelayExecutionButton(request: request, wallet: funding.wallet,
          account: funding.account, quote: quote)
          .id(quote.id)
      } else {
        RelaySolanaExecutionButton(request: request, wallet: funding.wallet,
          account: funding.account, quote: quote)
          .id(quote.id)
      }
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label).foregroundStyle(.secondary)
      Spacer(minLength: 10)
      Text(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
    }.font(AppTypography.callout)
  }
}
