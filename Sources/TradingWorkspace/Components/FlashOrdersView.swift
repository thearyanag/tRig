import SwiftUI

struct FlashOrdersView: View {
  let walletStore: WalletStore

  @State private var fundingWalletID: UUID?
  @State private var family: WalletFamily = .evm
  @State private var orders: [FlashOrder] = []
  @State private var nextPage: String?
  @State private var requestedCancel: FlashOrder?
  @State private var cancellingID: String?
  @State private var loading = false
  @State private var error: String?
  @State private var batchID = UUID()
  @State private var refreshID = UUID()
  @State private var observedFills: [String: String] = [:]

  private var funding: (wallet: TradingWallet, account: WalletAccount)? {
    walletStore.funding(walletID: fundingWalletID, family: family)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        Text("Flash orders").font(AppTypography.calloutMedium)
        Spacer()
        Picker("Network family", selection: $family) {
          ForEach(WalletFamily.allCases) { value in Text(value.title).tag(value) }
        }.labelsHidden().pickerStyle(.segmented).frame(width: 120)
        WalletFundingPicker(family: family, selection: $fundingWalletID).frame(maxWidth: 245)
        Button {
          refreshID = UUID()
        } label: {
          Image(systemName: "arrow.clockwise").frame(width: 26, height: 24)
        }
        .buttonStyle(TerminalControlStyle()).help("Refresh Flash orders")
        .accessibilityLabel("Refresh Flash orders")
        .disabled(loading || cancellingID != nil || funding == nil)
      }
      if let error {
        Text(error).font(AppTypography.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      if funding == nil {
        Text("Select a wallet to see its conditional orders.")
          .font(AppTypography.caption).foregroundStyle(.secondary)
      } else if orders.isEmpty && loading {
        ProgressView().controlSize(.small)
      } else if orders.isEmpty && nextPage == nil && error == nil {
        Text("No Flash orders for this wallet.")
          .font(AppTypography.caption).foregroundStyle(.secondary)
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(orders) { row($0) }
            if let nextPage {
              Button(loading ? "Loading…" : "Load older") {
                Task { await load(pageToken: nextPage) }
              }.buttonStyle(.link).disabled(loading || cancellingID != nil)
            }
          }
        }
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 8)
    .task(id: "\(funding?.account.id ?? ""):\(refreshID)") { await load() }
    .task(id: funding?.account.id) {
      while !Task.isCancelled, funding != nil {
        do { try await Task.sleep(for: .seconds(20)) } catch { return }
        if !loading, cancellingID == nil, orders.contains(where: { $0.canCancel || $0.status == "Cancel pending" }) {
          await load()
        }
      }
    }
    .onChange(of: family) { _, _ in fundingWalletID = nil }
    .confirmationDialog(
      "Cancel order?", isPresented: Binding(
        get: { requestedCancel != nil },
        set: { if !$0 { requestedCancel = nil } }),
      titleVisibility: .visible, presenting: requestedCancel
    ) { order in
      Button("Cancel \(order.typeLabel) order", role: .destructive) { cancel(order) }
    } message: { order in
      Text("\(order.asset) on \(order.chain) · \(order.quantity) \(order.spendAsset)")
    }
  }

  private func row(_ order: FlashOrder) -> some View {
    HStack(spacing: 10) {
      Text(order.asset).font(AppTypography.calloutMedium).frame(width: 90, alignment: .leading)
      Text(order.side.capitalized).frame(width: 36, alignment: .leading)
      Text(order.typeLabel).frame(width: 88, alignment: .leading)
      Text("\(order.quantity) \(order.spendAsset)").monospacedDigit()
      Spacer()
      if let price = order.price { Text("$\(price)").monospacedDigit() }
      Text(order.status).foregroundStyle(.secondary).frame(width: 95, alignment: .trailing)
      Button(cancellingID == order.id ? "Cancelling…" : "Cancel") {
        requestedCancel = order
      }
      .buttonStyle(.link).frame(width: 70, alignment: .trailing)
      .opacity(order.canCancel ? 1 : 0)
      .disabled(!order.canCancel || loading || walletStore.submitting || cancellingID != nil)
    }
    .font(AppTypography.caption)
    .padding(.vertical, 4).lineLimit(1)
  }

  private func load(pageToken: String? = nil) async {
    if pageToken == nil {
      orders = []
      nextPage = nil
    }
    let id = UUID()
    batchID = id
    error = nil
    guard let account = funding?.account else { loading = false; return }
    loading = true
    defer { if batchID == id { loading = false } }
    do {
      let result = try await FlashOrderClient().list(account: account, pageToken: pageToken)
      guard !Task.isCancelled, batchID == id else { return }
      let previous = Set(orders.map(\.id))
      orders += result.orders.filter { !previous.contains($0.id) }
      nextPage = result.nextPageToken
      if result.orders.reduce(into: false, { changed, order in
        guard let fill = order.filledQuantity, observedFills[order.id] != fill else { return }
        observedFills[order.id] = fill
        changed = true
      }) {
        walletStore.refreshBalances()
      }
    } catch {
      guard !Task.isCancelled, batchID == id else { return }
      self.error = error.localizedDescription
    }
  }

  private func cancel(_ order: FlashOrder) {
    guard let (wallet, account) = funding, cancellingID == nil, order.canCancel else { return }
    let selectedAccount = account.id
    let plan = FlashCancelPlan(orderId: order.id, funder: account.address, family: account.family)
    cancellingID = order.id
    error = nil
    Task {
      defer { cancellingID = nil }
      do {
        if !walletStore.isUnlocked { try await walletStore.unlock() }
        let result = try await walletStore.authorizeTrade(
          operation: .flashCancel, plan: plan, wallet: wallet, account: account
        ) { signed in
          try await FlashOrderClient().cancel(plan: plan, signature: signed)
        }
        if selectedAccount == funding?.account.id, let index = orders.firstIndex(where: { $0.id == order.id }) {
          orders[index] = result
        }
      } catch {
        if selectedAccount == funding?.account.id { self.error = error.localizedDescription }
      }
    }
  }
}
