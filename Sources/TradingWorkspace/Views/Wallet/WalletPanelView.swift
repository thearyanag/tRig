import AppKit
import SwiftUI

struct WalletControl: View {
  @Environment(WalletStore.self) private var store
  @State private var showing = false
  @State private var showingSetup = false
  @State private var setupAfterPopover = false
  @State private var selectedWalletID: UUID?
  let marketNetwork: String

  var body: some View {
    Button {
      if store.wallets.isEmpty && store.loadError == nil {
        showingSetup = true
      } else {
        showing.toggle()
      }
    } label: {
      Label(store.wallets.isEmpty ? "Wallet" : store.isUnlocked ? "Wallet" : "Wallet locked",
        systemImage: store.wallets.isEmpty ? "wallet.bifold" : store.isUnlocked ? "lock.open" : "lock")
        .font(AppTypography.caption).padding(.horizontal, 11).frame(height: 30)
    }
    .buttonStyle(TerminalControlStyle(glass: .init(cornerRadius: 15)))
    .accessibilityLabel("Wallet")
    .popover(isPresented: $showing, arrowEdge: .top) {
      WalletPanelView(marketNetwork: marketNetwork, selectedWalletID: $selectedWalletID) {
        setupAfterPopover = true
        showing = false
      }
        .preferredColorScheme(.dark)
        .onDisappear {
          guard setupAfterPopover else { return }
          setupAfterPopover = false
          Task { showingSetup = true }
        }
    }
    .sheet(isPresented: $showingSetup, onDismiss: {
      if !store.wallets.isEmpty { showing = true }
    }) {
      WalletSetupView(onComplete: { wallet in
        selectedWalletID = wallet.id
        showingSetup = false
      }, onCancel: { showingSetup = false })
      .id(store.lockID)
      .interactiveDismissDisabled(store.savingWallet)
      .preferredColorScheme(.dark)
    }
  }
}

struct WalletPanelView: View {
  let marketNetwork: String
  @Binding var selectedWalletID: UUID?
  let onAddWallet: () -> Void
  @Environment(WalletStore.self) private var store

  private enum Screen { case home, receive, send, backup, activity }
  @State private var screen = Screen.home
  @State private var sendFamily = WalletFamily.solana
  @State private var networkID = "solana"
  @State private var networks = [WalletNetwork.solana]
  @State private var networkError: String?
  @State private var loadedBalance: WalletNetworkClient.Balance?
  @State private var loadedBalanceKey: String?
  @State private var loadingBalance = false
  @State private var balanceError: String?
  @State private var showingAddresses = false
  @State private var error: String?
  @State private var backup: WalletSecret?
  @State private var walletAction: Task<Void, Never>?

  private var wallet: TradingWallet? {
    store.wallets.first { $0.id == selectedWalletID } ?? store.wallets.first
  }

  private var walletNetworks: [WalletNetwork] {
    guard let wallet else { return [] }
    return networks.filter { network in wallet.accounts.contains { $0.family == network.family } }
  }

  private var network: WalletNetwork? {
    let selected = walletNetworks.first { $0.id == networkID }
    if screen == .send {
      return selected?.family == sendFamily ? selected : nil
    }
    return selected ?? walletNetworks.first
  }

  private var account: WalletAccount? {
    guard let network else { return nil }
    return wallet?.accounts.first { $0.family == network.family }
  }

  private var balanceKey: String {
    [network?.id ?? "", account?.id ?? ""].joined(separator: ":")
  }

  private var balance: WalletNetworkClient.Balance? {
    loadedBalanceKey == balanceKey ? loadedBalance : nil
  }

  private var emptyBalance: Bool { balance.map { Decimal(string: $0.amount) == .zero } == true }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      switch screen {
      case .home: home
      case .receive: receive
      case .send:
        if let wallet, let account = wallet.addressAccounts.first(where: { $0.family == sendFamily }) {
          WalletSendView(wallet: wallet, network: network, account: account, balance: balance?.amount,
            availableNetworks: walletNetworks, family: $sendFamily, networkID: $networkID,
            onBack: { goHome() })
            .id("\(sendFamily.rawValue):\(networkID):\(account.id)")
        }
      case .backup: backupScreen
      case .activity:
        backHeader("Wallet Activity")
        WalletActivityView(store: store, wallet: wallet)
      }
      if let error { Text(error).font(AppTypography.caption).foregroundStyle(.orange) }
    }
    .padding(17)
    .frame(width: 380)
    .background(TerminalStyle.panel)
    .task {
      do {
        networks = try await WalletNetworkClient().networks()
        if screen == .home { chooseNetwork(preferred: marketNetwork) }
      } catch {
        if !Task.isCancelled { networkError = "Couldn’t load the wallet network list." }
      }
    }
    .task(id: balanceKey + ":" + store.balanceRefreshID.uuidString) { await readBalance() }
    .onChange(of: marketNetwork) { _, market in
      if screen == .home { chooseNetwork(preferred: market) }
    }
    .onChange(of: store.lockID) { _, _ in
      backup = nil
      walletAction?.cancel()
      if screen == .backup || screen == .send { goHome() }
    }
    .onDisappear { backup = nil; walletAction?.cancel() }
  }

  private var home: some View {
    VStack(alignment: .leading, spacing: 13) {
      if let loadError = store.loadError { Text(loadError).foregroundStyle(.orange) }
      if let wallet {
        walletHeader(wallet)
        Divider()
        balanceSummary
        if let networkError { Text(networkError).font(AppTypography.caption).foregroundStyle(.orange) }
        HStack(spacing: 8) {
          walletActionButton(
            emptyBalance ? "Receive \(network?.symbol ?? "")" : "Receive",
            icon: "arrow.down.to.line", primary: emptyBalance
          ) { open(.receive) }
          .disabled(wallet.addressAccounts.isEmpty)
          walletActionButton("Send", icon: "arrow.up.right") { open(.send) }
            .disabled(network == nil || (emptyBalance && walletNetworks.count == 1))
          walletActionButton("Activity", icon: "clock") { open(.activity) }
        }
      }
    }
  }

  private func walletHeader(_ wallet: TradingWallet) -> some View {
    HStack(spacing: 8) {
      Menu {
        ForEach(store.wallets) { item in
          Button {
            showingAddresses = false
            selectedWalletID = item.id
            chooseNetwork(preferred: marketNetwork)
          } label: {
            if item.id == wallet.id { Label(item.label, systemImage: "checkmark") }
            else { Text(item.label) }
          }
        }
        Divider()
        Button("Add wallet", action: onAddWallet)
      } label: {
        Label(wallet.label, systemImage: "wallet.bifold")
          .font(AppTypography.bodySemibold).lineLimit(1)
      }
      .menuStyle(.borderlessButton)
      .accessibilityLabel("Switch wallet")

      Button { showingAddresses.toggle() } label: {
        Image(systemName: "document.on.document").frame(width: 27, height: 26)
          .background(showingAddresses ? TerminalStyle.accent.opacity(0.16) : .clear,
            in: RoundedRectangle(cornerRadius: 6))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Copy wallet address")
      .help("Copy wallet address")
      .popover(isPresented: $showingAddresses, arrowEdge: .top) {
        WalletAddressPicker(accounts: wallet.addressAccounts)
      }
      Spacer(minLength: 4)
      Button(action: toggleLock) {
        Label(store.isUnlocked ? "Unlocked" : "Locked",
          systemImage: store.isUnlocked ? "lock.open" : "lock")
          .font(AppTypography.caption).padding(.horizontal, 7).frame(height: 26)
          .background(TerminalStyle.field, in: RoundedRectangle(cornerRadius: 6))
      }
      .buttonStyle(.plain)
      .foregroundStyle(store.isUnlocked ? TerminalStyle.buy : .secondary)
      .accessibilityLabel(store.isUnlocked ? "Lock wallet" : "Unlock wallet")
      .help(store.isUnlocked ? "Lock wallet" : "Unlock wallet")
      .disabled(store.authorizing)
      Menu {
        Button("Show backup") { showBackup(wallet) }.disabled(store.authorizing)
      } label: {
        Image(systemName: "ellipsis").frame(width: 22, height: 26)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .accessibilityLabel("Wallet settings")
    }
  }

  private var balanceSummary: some View {
    VStack(alignment: .leading, spacing: 5) {
      if let network {
        if let balance {
          Text("\(balance.amount) \(network.symbol)").font(AppTypography.titleBold)
          Text("Available on \(network.name)").foregroundStyle(.secondary)
          if emptyBalance {
            Text("Add \(network.symbol) to this wallet to get started.")
              .font(AppTypography.caption).foregroundStyle(.secondary).padding(.top, 5)
          }
        } else if let balanceError, !loadingBalance {
          Text(balanceError).font(AppTypography.caption).foregroundStyle(.secondary)
        } else {
          ProgressView("Reading \(network.name) balance…").controlSize(.small)
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func walletActionButton(_ title: String, icon: String, primary: Bool = false,
    action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: icon)
        .font(AppTypography.calloutMedium).lineLimit(1)
        .frame(maxWidth: .infinity).frame(height: 34)
    }
    .buttonStyle(primary ? TerminalControlStyle.primary : TerminalControlStyle(
      fill: TerminalStyle.field, border: TerminalStyle.border))
  }

  private func open(_ value: Screen) {
    showingAddresses = false
    error = nil
    if value == .send {
      sendFamily = network?.family ?? wallet?.addressAccounts.first?.family ?? .solana
      networkID = network?.id ?? ""
    }
    screen = value
  }

  private func goHome() {
    backup = nil
    error = nil
    chooseNetwork(preferred: marketNetwork)
    screen = .home
  }

  private func toggleLock() {
    if store.isUnlocked { store.lock(); return }
    walletAction = Task {
      do { try await store.unlock() }
      catch is CancellationError { }
      catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
  }

  private var receive: some View {
    VStack(alignment: .leading, spacing: 13) {
      backHeader("Receive")
      if let wallet {
        WalletReceiveView(
          accounts: wallet.addressAccounts,
          preferredFamily: marketNetwork.hasPrefix("eip155:") ? .evm : .solana)
      }
    }
  }

  private var backupScreen: some View {
    VStack(alignment: .leading, spacing: 12) {
      backHeader("Wallet backup")
      if let backup {
        VStack(alignment: .leading, spacing: 8) {
          Text(backup.kind == .phrase ? "Recovery phrase" : "Private key")
            .font(AppTypography.caption).foregroundStyle(.secondary)
          Text(verbatim: backup.value).monospaced().textSelection(.enabled)
          if let phrase = backup.passphrase, !phrase.isEmpty {
            Divider()
            Text("BIP39 passphrase").font(AppTypography.caption).foregroundStyle(.secondary)
            Text(verbatim: phrase).monospaced().textSelection(.enabled)
          }
          if let index = backup.accountIndex, index > 0 {
            Text("Account index \(index)").font(AppTypography.caption).foregroundStyle(.secondary)
          }
        }
        .walletCard()
      }
      Button(action: goHome) {
        Label("Hide backup", systemImage: "eye.slash")
          .font(AppTypography.calloutMedium)
          .frame(maxWidth: .infinity).frame(height: 36)
      }.buttonStyle(TerminalControlStyle.primary)
    }
  }

  private func backHeader(_ title: String) -> some View {
    HStack {
      Button(action: goHome) {
        Image(systemName: "chevron.left").frame(width: 20, height: 22)
      }.buttonStyle(.borderless).accessibilityLabel("Back to wallet")
      Text(title).font(AppTypography.headline)
    }
  }

  private func chooseNetwork(preferred: String) {
    if walletNetworks.contains(where: { $0.id == preferred }) { networkID = preferred }
    else if let first = walletNetworks.first { networkID = first.id }
  }

  private func readBalance() async {
    let key = balanceKey
    loadedBalance = nil; loadedBalanceKey = nil; balanceError = nil; loadingBalance = false
    guard let network, let account else { return }
    loadingBalance = true
    defer { if !Task.isCancelled { loadingBalance = false } }
    do {
      let value = try await WalletNetworkClient().balance(network: network, account: account)
      guard !Task.isCancelled, key == balanceKey else { return }
      loadedBalance = value
      loadedBalanceKey = key
    }
    catch { if !Task.isCancelled { balanceError = error.localizedDescription } }
  }

  private func showBackup(_ wallet: TradingWallet) {
    error = nil
    walletAction = Task {
      do {
        let value = try await store.revealBackup(for: wallet)
        try Task.checkCancellation()
        backup = value
        screen = .backup
      } catch is CancellationError { }
      catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
  }

}
