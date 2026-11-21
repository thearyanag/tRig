import SwiftUI

/// Native quote ticket for chain-aware token pairs. No wallet is connected here.
struct EVMMarketQuoteView: View {
  let asset: Asset
  @Binding var trade: TradeDraft
  @State private var counterAsset: Asset?
  @State private var showPicker = false
  @State private var sender = ""
  @State private var recipient = ""
  @State private var store = ExecutionQuoteStore()
  @State private var details = false
  @FocusState private var amountFocused: Bool
  private var counter: Asset? {
    counterAsset
      ?? asset.settlement.map {
        Asset(
          id: $0.address, name: $0.name, symbol: $0.symbol, network: asset.network,
          pool: "", decimals: $0.decimals, priceUsd: nil, imageURL: $0.imageUrl,
          chainId: asset.chainID)
      }
  }
  private var inputAsset: Asset? { trade.side == .buy ? counter : asset }
  private var outputAsset: Asset? { trade.side == .buy ? asset : counter }
  private var crossChain: Bool { inputAsset?.chainID != outputAsset?.chainID }
  private var request: ExecutionQuoteRequest {
    ExecutionQuoteRequest(
      provider: nil, side: trade.side.rawValue.lowercased(),
      input: .init(chain: inputAsset?.chainID ?? "", address: inputAsset?.id ?? ""),
      output: .init(chain: outputAsset?.chainID ?? "", address: outputAsset?.id ?? ""),
      amount: trade.amountText.trimmingCharacters(in: .whitespacesAndNewlines), orderType: .market,
      slippageBps: SwapQuoteInput(asset: asset, draft: trade).slippageBps,
      context: .init(
        sender: sender.isEmpty ? nil : sender, recipient: recipient.isEmpty ? nil : recipient))
  }
  private var validContext: Bool {
    Asset.validAddress(sender, chain: request.input.chain)
      && (!crossChain || Asset.validAddress(recipient, chain: request.output.chain))
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
          }.padding(10).background(TerminalStyle.field)
          Text("Receive estimate").font(AppTypography.caption).foregroundStyle(.secondary)
          HStack {
            token(outputAsset, selectable: trade.side == .sell)
            Spacer(minLength: 0)
            Text(quote.map { PortfolioFormat.quantity($0.receiveAmount) } ?? "—")
              .font(AppTypography.font(size: 17, weight: .medium)).monospacedDigit().lineLimit(1)
              .minimumScaleFactor(0.6)
          }.padding(10).background(TerminalStyle.field)
          if crossChain {
            Label(
              "\(inputAsset?.network ?? "") → \(outputAsset?.network ?? "")",
              systemImage: "arrow.left.arrow.right"
            )
            .font(AppTypography.caption).foregroundStyle(.secondary)
          }
          VStack(alignment: .leading, spacing: 5) {
            Text("Public sender address").font(AppTypography.caption).foregroundStyle(.secondary)
            TextField("Address on \(inputAsset?.network ?? asset.network)", text: $sender)
              .textFieldStyle(.plain).padding(8).background(TerminalStyle.field)
              .accessibilityLabel("Public sender address for quote")
            if crossChain {
              Text("Public destination address").font(AppTypography.caption).foregroundStyle(
                .secondary)
              TextField("Address on \(outputAsset?.network ?? asset.network)", text: $recipient)
                .textFieldStyle(.plain).padding(8).background(TerminalStyle.field)
                .accessibilityLabel("Public destination address for quote")
            }
            Text("Used to estimate the route. No wallet is connected or authorized.")
              .font(AppTypography.caption).foregroundStyle(.secondary)
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
          }.buttonStyle(
            TerminalControlStyle(
              fill: TerminalStyle.accent, foreground: .white, border: TerminalStyle.accent)
          )
          .disabled(
            !request.isValid || !validContext || store.isLoading || asset.marketQuotes == false)
          Text(
            asset.marketQuotes == false
              ? "Market quotes are unavailable on this network." : "Quote only. No order is placed."
          )
          .font(AppTypography.caption).foregroundStyle(.secondary)
        }.padding(12).background(TerminalStyle.panel).overlay(alignment: .top) { Divider() }
      }
    }
    .font(AppTypography.body)
    .onChange(of: request) { _, value in if store.request != value { store.clear() } }
    .onChange(of: request.input.chain) { _, _ in sender = "" }
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
