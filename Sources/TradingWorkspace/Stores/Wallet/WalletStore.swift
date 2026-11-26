import AppKit
import CryptoKit
import LocalAuthentication
import Observation

@MainActor @Observable
final class WalletStore {
  private(set) var wallets: [TradingWallet] = []
  private(set) var unlockUntil: Date?
  private(set) var authorizing = false
  private(set) var savingWallet = false
  private(set) var submitting = false
  let activity: WalletActivityStore
  let trades: WalletTradeJournal
  private(set) var balanceRefreshID = UUID()
  private(set) var loadError: String?
  var isUnlocked: Bool { unlockUntil != nil }

  @ObservationIgnored private let vault: WalletVault
  @ObservationIgnored private let accessKey: @Sendable (WalletVault, LAContext, Bool) throws -> SymmetricKey
  @ObservationIgnored private var records: [WalletVault.Record] = []
  @ObservationIgnored private var unlockKey: SymmetricKey?
  @ObservationIgnored private var deadline: ContinuousClock.Instant?
  @ObservationIgnored private var expiry: Task<Void, Never>?
  @ObservationIgnored private var authorization: Authorization?
  private(set) var lockID = UUID()
  private let duration: Duration = .seconds(3 * 60 * 60)

  init(vault: WalletVault = .onDevice,
    accessKey: @escaping @Sendable (WalletVault, LAContext, Bool) throws -> SymmetricKey = {
      try $0.key(context: $1, createIfMissing: $2)
    }) {
    self.vault = vault
    self.accessKey = accessKey
    activity = WalletActivityStore(vault: vault)
    trades = WalletTradeJournal(vault: vault)
    do {
      records = try vault.read()
      wallets = records.map(\.wallet)
    } catch {
      loadError = "Couldn’t open your saved wallet vault."
    }
  }

  func observeLocks() async {
    let workspace = NSWorkspace.shared.notificationCenter
    let distributed = DistributedNotificationCenter.default()
    let observers = [
      NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
      NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
    ].map { name in
      workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.lock() }
      }
    }
    let screenLock = distributed.addObserver(
      forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.lock() }
    }
    defer {
      observers.forEach(workspace.removeObserver)
      distributed.removeObserver(screenLock)
      lock()
    }
    do { try await Task.sleep(for: .seconds(Int64.max / 1_000_000_000)) } catch { }
  }

  func lock() {
    lockID = UUID()
    authorization?.invalidate()
    authorization = nil
    authorizing = false
    expiry?.cancel()
    expiry = nil
    unlockKey = nil
    deadline = nil
    unlockUntil = nil
  }

  private func currentKey() -> SymmetricKey? {
    guard let deadline, ContinuousClock.now < deadline else {
      if unlockKey != nil { lock() }
      return nil
    }
    return unlockKey
  }

  func unlock() async throws {
    guard !wallets.isEmpty else { throw WalletFailure("Add a wallet first.") }
    if currentKey() != nil { return }
    let (key, session) = try await authenticate(reason: "Unlock your tRig wallet.", createIfMissing: false)
    guard lockID == session else { throw CancellationError() }
    unlockKey = key
    let clock = ContinuousClock()
    let expiryTime = clock.now.advanced(by: duration)
    deadline = expiryTime
    unlockUntil = Date.now.addingTimeInterval(3 * 60 * 60)
    expiry = Task { [weak self] in
      do { try await clock.sleep(until: expiryTime) } catch { return }
      guard let self, self.lockID == session else { return }
      self.lock()
    }
  }

  func add(_ secret: WalletSecret, accounts: [WalletAccount]) async throws -> TradingWallet {
    guard !savingWallet else { throw WalletFailure("A wallet is already being saved.") }
    savingWallet = true
    // Once confirmed, the save can finish even if the setup presentation goes away.
    let save = Task {
      defer { savingWallet = false }
      return try await saveWallet(secret, accounts: accounts)
    }
    return try await save.value
  }

  private func saveWallet(_ secret: WalletSecret, accounts: [WalletAccount]) async throws -> TradingWallet {
    if let loadError { throw WalletFailure(loadError) }
    try checkNewAccounts(accounts)
    let (key, session) = try await authenticate(
      reason: "Protect your trading wallet in Keychain.", createIfMissing: records.isEmpty)
    guard lockID == session else { throw CancellationError() }
    try checkNewAccounts(accounts)
    let label = wallets.isEmpty ? "Trading wallet" : "Wallet \(wallets.count + 1)"
    let wallet = TradingWallet(id: UUID(), label: label, accounts: accounts, source: secret.kind)
    let record = try vault.seal(secret, wallet: wallet, using: key)
    let updated = records + [record]
    try vault.save(updated)
    records = updated
    wallets.append(wallet)
    return wallet
  }

  func revealBackup(for wallet: TradingWallet) async throws -> WalletSecret {
    guard let record = records.first(where: { $0.wallet.id == wallet.id }) else {
      throw WalletFailure("Wallet unavailable.")
    }
    let (key, session) = try await authenticate(reason: "Show this wallet’s backup.", createIfMissing: false)
    guard lockID == session else { throw CancellationError() }
    return try vault.open(record, using: key)
  }

  func funding(walletID: UUID?, family: WalletFamily) -> (wallet: TradingWallet, account: WalletAccount)? {
    for wallet in wallets where walletID == nil || wallet.id == walletID {
      if let account = wallet.accounts.first(where: { $0.family == family }) {
        return (wallet, account)
      }
    }
    return nil
  }

  func refreshBalances() { balanceRefreshID = UUID() }

  func activityItems(for wallet: TradingWallet? = nil) -> [WalletActivityItem] {
    let transfers = activity.entries.filter { entry in
      guard let wallet else { return true }
      return wallet.accounts.contains {
        $0.identityAddress == ($0.family == .evm ? entry.intent.from.lowercased() : entry.intent.from)
      }
    }.map(WalletActivityItem.init(transfer:))
    let tradeItems = trades.entries.filter { wallet == nil || $0.walletID == wallet?.id }
      .map(WalletActivityItem.init(trade:))
    return (transfers + tradeItems).sorted { $0.date > $1.date }
  }

  func refreshActivity() async {
    let confirmedTransfers = Set(activity.entries.filter { $0.status == .confirmed }.map(\.id))
    async let transfers: Void = activity.refresh()
    async let confirmedTrade = trades.refresh()
    await transfers
    if await confirmedTrade || activity.entries.contains(where: {
      $0.status == .confirmed && !confirmedTransfers.contains($0.id)
    }) {
      refreshBalances()
    }
  }

  func performTradeStep<Plan: Encodable & Sendable>(
    operation: WalletTradeOperation, plan: Plan, wallet: TradingWallet, account: WalletAccount,
    activity: WalletTradeDetails, submit: @MainActor (WalletSignedTransfer) async throws -> WalletTradeStatus
  ) async throws -> WalletTradeActivity {
    try trades.checkNew(activity)
    return try await authorizeTrade(
      operation: operation, plan: plan, wallet: wallet, account: account, expiresAt: activity.expiresAt
    ) { signed in
      let entry = WalletTradeActivity(
        details: activity, walletID: wallet.id, address: account.address,
        transactionID: signed.transactionId, createdAt: .now, status: .pending)
      try trades.record(entry)
      // A dropped response can follow a successful submission. Check the recorded ID before retrying.
      if let status = try? await submit(signed) { try? trades.update(entry.id, to: status) }
      let result = trades.entries.first { $0.id == entry.id } ?? entry
      if result.status == .confirmed { refreshBalances() }
      return result
    }
  }

  func authorizeTrade<Plan: Encodable & Sendable, Result: Sendable>(
    operation: WalletTradeOperation, plan: Plan, wallet: TradingWallet, account: WalletAccount,
    expiresAt: Date? = nil, submit: @MainActor (WalletSignedTransfer) async throws -> Result
  ) async throws -> Result {
    guard !submitting else { throw WalletFailure("Another wallet transaction is being submitted.") }
    guard let record = records.first(where: { $0.wallet == wallet }), wallet.accounts.contains(account)
    else { throw WalletFailure("The funding wallet is unavailable.") }
    if let family = operation.fundingFamily, account.family != family {
      throw WalletFailure("Choose a wallet for this network.")
    }
    guard expiresAt.map({ $0 > .now }) ?? true else {
      throw WalletFailure("Refresh this quote before trading.")
    }
    guard let key = currentKey() else { throw WalletFailure("Unlock your wallet to sign.") }
    let session = lockID
    submitting = true
    defer { submitting = false }

    let secret = try vault.open(record, using: key)
    let signed = try await WalletDerivation.signTrade(operation, plan: plan, with: secret)
    try Task.checkCancellation()
    guard lockID == session, currentKey() != nil, expiresAt.map({ $0 > .now }) ?? true
    else { throw WalletFailure("Unlock your wallet and review a fresh quote.") }
    return try await submit(signed)
  }

  func send(_ plan: WalletTransferPlan, from wallet: TradingWallet,
    network: WalletNetwork, account: WalletAccount, symbol: String) async throws -> (String, Bool) {
    guard !submitting else { throw WalletFailure("Another wallet transfer is being submitted.") }
    guard !plan.expired, plan.intent.chain == network.id, plan.intent.from == account.address,
      plan.parameters.family == account.family, wallet.accounts.contains(account),
      plan.feeDecimals == network.decimals,
      plan.intent.tokenAddress != nil || plan.decimals == network.decimals,
      plan.intent.atomicUnits(decimals: plan.decimals) == plan.amountAtomic,
      let record = records.first(where: { $0.wallet == wallet })
    else { throw WalletFailure("Review a fresh transfer before sending.") }
    guard let key = currentKey() else { throw WalletFailure("Unlock your wallet to sign.") }
    guard !activity.entries.contains(where: { item in
      item.status == .pending && item.intent.matches(plan.intent, decimals: plan.decimals)
    }) else {
      throw WalletFailure("An identical send is still pending in Activity. Check its status first.")
    }
    let session = lockID
    submitting = true
    defer { submitting = false }
    let transaction = try await signTransfer(plan, record: record, key: key)
    try Task.checkCancellation()
    guard lockID == session, currentKey() != nil, !plan.expired else {
      throw WalletFailure("Unlock your wallet and review a fresh transfer.")
    }

    let entry = WalletTransferActivity(id: transaction.transactionId, intent: plan.intent,
      network: network.name, symbol: symbol, createdAt: .now, status: .pending,
      lastValidBlockHeight: plan.parameters.lastValidBlockHeight)
    try activity.record(entry)
    do {
      try await WalletTransferClient().submit(transaction, chain: network.id)
      refreshBalances()
      return (transaction.transactionId, true)
    } catch {
      // The RPC may have accepted the transaction before its response was lost.
      return (transaction.transactionId, false)
    }
  }

  private func signTransfer(_ plan: WalletTransferPlan, record: WalletVault.Record,
    key: SymmetricKey) async throws -> WalletSignedTransfer {
    let secret = try vault.open(record, using: key)
    return try await WalletDerivation.sign(plan, with: secret)
  }

  private func checkNewAccounts(_ accounts: [WalletAccount]) throws {
    let known = Set(wallets.flatMap(\.accounts).map(\.id))
    guard !accounts.isEmpty, !accounts.contains(where: { known.contains($0.id) }) else {
      throw WalletFailure("One of these accounts is already in your wallet list.")
    }
  }

  private func authenticate(reason: String, createIfMissing: Bool) async throws -> (SymmetricKey, UUID) {
    guard !authorizing else { throw WalletFailure("Finish the current wallet authentication first.") }
    let session = lockID
    let request = Authorization(reason: reason)
    authorizing = true
    authorization = request
    defer {
      request.invalidate()
      if authorization === request {
        authorizing = false
        authorization = nil
      }
    }
    let vault = self.vault
    let accessKey = self.accessKey
    let key = try await Task.detached(priority: .userInitiated) {
      try accessKey(vault, request.context, createIfMissing)
    }.value
    try Task.checkCancellation()
    guard lockID == session else { throw CancellationError() }
    return (key, session)
  }
}

// The worker owns the Keychain operation. The main actor can invalidate its context on lock.
private final class Authorization: @unchecked Sendable {
  let context = LAContext()

  init(reason: String) { context.localizedReason = reason }

  func invalidate() { context.invalidate() }
}
