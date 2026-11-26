import SwiftUI

struct JupiterTriggerOrdersView: View {
  let walletStore: WalletStore

  @State private var fundingWalletID: UUID?
  @State private var session: JupiterTriggerSessionStatus?
  @State private var orders: [JupiterTriggerOrder] = []
  @State private var nextOffset: Int?
  @State private var requestedCancel: JupiterTriggerOrder?
  @State private var withdrawal: JupiterTriggerWithdrawal?
  @State private var preparingID: String?
  @State private var loading = false
  @State private var loadError: String?
  @State private var actionError: String?
  @State private var listAccountID: String?
  @State private var selectionID = UUID()
  @State private var observedFills: [String: String] = [:]

  private var funding: (wallet: TradingWallet, account: WalletAccount)? {
    walletStore.funding(walletID: fundingWalletID, family: .solana)
  }

  private var updating: Bool { loading || preparingID != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      if let error = actionError ?? loadError {
        Text(error).font(AppTypography.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      content
    }
    .padding(.horizontal, 16).padding(.vertical, 8)
    .task(id: funding?.account.id) {
      selectionID = UUID()
      listAccountID = funding?.account.id
      orders = []
      nextOffset = nil
      session = nil
      observedFills = [:]
      actionError = nil
      loadError = nil
      loading = false
      guard let account = funding?.account else { return }
      await load(account: account)
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(20)) } catch { return }
        if session?.authenticated == true, !updating, requestedCancel == nil, withdrawal == nil {
          await load(account: account)
        }
      }
    }
    .onChange(of: walletStore.isUnlocked && !walletStore.submitting) { _, canSignIn in
      if canSignIn, session?.authenticated == false { refresh() }
    }
    .confirmationDialog(
      "Review Jupiter cancellation",
      isPresented: Binding(
        get: { requestedCancel != nil },
        set: { if !$0 { requestedCancel = nil } }),
      titleVisibility: .visible,
      presenting: requestedCancel
    ) { order in
      Button(order.needsWithdrawal ? "Review withdrawal" : "Stop order and review withdrawal",
        role: order.needsWithdrawal ? nil : .destructive) {
        prepareWithdrawal(order)
      }
    } message: { order in
      Text(order.needsWithdrawal
        ? "Review the return of your remaining funds to the funding wallet."
        : "Jupiter stops this order when you continue. You’ll then review the withdrawal to the funding wallet.")
    }
    .sheet(item: $withdrawal, onDismiss: refresh) {
      JupiterTriggerWithdrawalReview(withdrawal: $0, walletStore: walletStore)
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Text("Jupiter orders").font(AppTypography.calloutMedium)
      Spacer()
      WalletFundingPicker(family: .solana, selection: $fundingWalletID)
        .frame(maxWidth: 250)
        .disabled(preparingID != nil)
      Button(action: refresh) {
        Image(systemName: "arrow.clockwise").frame(width: 26, height: 24)
      }
      .buttonStyle(TerminalControlStyle())
      .help("Refresh Jupiter orders")
      .accessibilityLabel("Refresh Jupiter orders")
      .disabled(updating || funding == nil)
    }
  }

  @ViewBuilder private var content: some View {
    if let current = funding {
      if listAccountID != current.account.id {
        ProgressView("Loading orders…").controlSize(.small)
      } else if session?.authenticated == false {
        if loading || walletStore.submitting {
          ProgressView("Loading orders…").controlSize(.small)
        } else {
          Button(walletStore.isUnlocked ? "Retry loading orders" : "Unlock wallet") {
            Task { await load(account: current.account, unlockIfNeeded: true) }
          }.buttonStyle(.link)
        }
      } else if orders.isEmpty {
        if loading {
          ProgressView("Loading orders…").controlSize(.small)
        } else if session?.authenticated == true && loadError == nil {
          Text("No Jupiter orders for this wallet.")
            .font(AppTypography.caption).foregroundStyle(.secondary)
        }
      } else {
        orderList(account: current.account)
      }
    } else {
      Text("Add a Solana wallet to see your Jupiter orders.")
        .font(AppTypography.caption).foregroundStyle(.secondary)
    }
  }

  private func orderList(account: WalletAccount) -> some View {
    ScrollView {
      LazyVStack(spacing: 2) {
        ForEach(orders) { order in
          let pending = JupiterTriggerWithdrawal.pending(
            order: order, account: account, entries: walletStore.trades.entries)
          HStack(spacing: 10) {
            Text(order.pair).font(AppTypography.calloutMedium).frame(width: 124, alignment: .leading)
              .help("\(order.inputMint) → \(order.outputMint)")
            Text(order.name).frame(width: 78, alignment: .leading)
            Text(order.amount).monospacedDigit()
            Spacer(minLength: 8)
            if let price = order.price { Text(price).monospacedDigit() }
            Text(pending ? "Withdrawal pending" : order.status)
              .foregroundStyle(.secondary).frame(width: 125, alignment: .trailing)
            if order.canCancel {
              Button(order.needsWithdrawal ? "Withdraw" : "Cancel") { requestedCancel = order }
                .buttonStyle(.link)
                .frame(width: 64, alignment: .trailing)
                .disabled(updating || walletStore.submitting || pending)
            } else {
              Spacer().frame(width: 64)
            }
          }
          .font(AppTypography.caption)
          .lineLimit(1)
          .padding(.vertical, 4)
        }
        if let nextOffset {
          Button("Load more orders") { Task { await load(account: account, offset: nextOffset) } }
            .buttonStyle(.link).font(AppTypography.caption).disabled(updating)
        }
      }
    }
  }

  private func refresh() {
    guard let account = funding?.account else { return }
    Task { await load(account: account) }
  }

  private func load(account: WalletAccount, offset: Int = 0, unlockIfNeeded: Bool = false) async {
    guard let funding, funding.account == account, !loading else { return }
    let selection = selectionID
    loading = true
    loadError = nil
    defer { if selection == selectionID { loading = false } }
    do {
      let current = try await JupiterTriggerSession().authenticate(
        walletStore: walletStore, wallet: funding.wallet, account: account, unlockIfNeeded: unlockIfNeeded)
      guard !Task.isCancelled, selection == selectionID, self.funding?.account == account else { return }
      session = current
      guard current.authenticated else {
        orders = []
        nextOffset = nil
        return
      }
      let result = try await JupiterTriggerManagementClient().orders(account: account, offset: offset)
      guard !Task.isCancelled, selection == selectionID, self.funding?.account == account else { return }
      if offset == 0 {
        orders = result.orders
      } else {
        let ids = Set(orders.map(\.id))
        orders += result.orders.filter { !ids.contains($0.id) }
      }
      nextOffset = result.nextOffset
      if result.orders.reduce(into: false, { changed, order in
        guard let fill = order.outputAmount, fill != "0", observedFills[order.id] != fill else { return }
        observedFills[order.id] = fill
        changed = true
      }) {
        walletStore.refreshBalances()
      }
    } catch is CancellationError {
    } catch {
      guard !Task.isCancelled, selection == selectionID, self.funding?.account == account else { return }
      loadError = error.localizedDescription
    }
  }

  private func prepareWithdrawal(_ order: JupiterTriggerOrder) {
    guard order.canCancel, !updating, let current = funding,
      listAccountID == current.account.id,
      orders.contains(where: { $0.id == order.id }),
      !JupiterTriggerWithdrawal.pending(order: order, account: current.account, entries: walletStore.trades.entries)
    else { return }
    preparingID = order.id
    actionError = nil
    Task {
      defer { preparingID = nil }
      do {
        let plan = try await JupiterTriggerManagementClient().withdraw(
          order, walletStore: walletStore, wallet: current.wallet, account: current.account)
        guard funding?.account == current.account else { return }
        withdrawal = JupiterTriggerWithdrawal(order: order, plan: plan,
          wallet: current.wallet, account: current.account)
      } catch is CancellationError {
      } catch {
        actionError = error.localizedDescription
      }
      await load(account: current.account)
    }
  }
}
