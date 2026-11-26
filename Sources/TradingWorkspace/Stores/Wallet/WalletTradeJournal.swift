import Foundation
import Observation

@MainActor @Observable
final class WalletTradeJournal {
  private(set) var entries: [WalletTradeActivity] = []
  private(set) var refreshing = false
  private let file: URL
  private let loadFailure: Bool
  private var nextPending = 0

  init(vault: WalletVault) {
    file = vault.url.deletingLastPathComponent().appending(path: "trades.json")
    do {
      entries = try JSONDecoder().decode([WalletTradeActivity].self, from: Data(contentsOf: file))
      loadFailure = false
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      loadFailure = false
    } catch {
      loadFailure = true
    }
  }

  func checkNew(_ details: WalletTradeDetails) throws {
    guard !loadFailure else { throw WalletFailure("Couldn’t open the trading activity file.") }
    guard !entries.contains(where: {
      $0.details.provider == details.provider && $0.details.chain == details.chain
        && $0.details.requestID == details.requestID
    }) else {
      throw WalletFailure("This request is already in Activity. Check its status before trading again.")
    }
  }

  func record(_ entry: WalletTradeActivity) throws {
    try checkNew(entry.details)
    guard !entries.contains(where: { $0.id == entry.id }) else {
      throw WalletFailure("This transaction is already in Activity.")
    }
    try save([entry] + entries)
  }

  func update(_ id: String, to status: WalletTradeStatus) throws {
    guard status != .pending,
      let index = entries.firstIndex(where: { $0.id == id && $0.status == .pending })
    else { return }
    var updated = entries
    updated[index].status = status
    try save(updated)
  }

  func refresh() async -> Bool {
    guard !refreshing else { return false }
    refreshing = true
    defer { refreshing = false }
    var confirmed = false
    let pending = entries.filter { $0.status == .pending }
    guard !pending.isEmpty else { return false }
    let start = nextPending % pending.count
    let count = min(10, pending.count)
    nextPending = (start + count) % pending.count
    for offset in 0..<count {
      let entry = pending[(start + offset) % pending.count]
      if Task.isCancelled { break }
      guard let status = try? await checkStatus(entry), status != .pending else { continue }
      do {
        try update(entry.id, to: status)
        confirmed = confirmed || status == .confirmed
      } catch { break }
    }
    return confirmed
  }

  private func checkStatus(_ entry: WalletTradeActivity) async throws -> WalletTradeStatus {
    let path: String
    switch entry.details.provider {
    case .jupiter: path = "api/swap/jupiter/status"
    case .relay: path = "api/wallet/trade/relay/status"
    case .jupiterTrigger, .relayApproval, .flashApproval: path = "api/wallet/transfer/status"
    }
    var query = [
      URLQueryItem(name: "chain", value: entry.details.chain),
      URLQueryItem(name: "transactionId", value: entry.transactionID),
    ]
    if entry.details.provider == .jupiter || entry.details.provider == .relay {
      query.append(URLQueryItem(name: "requestId", value: entry.details.requestID))
    }
    if let height = entry.details.lastValidBlockHeight {
      query.append(URLQueryItem(name: "lastValidBlockHeight", value: String(height)))
    }
    struct Status: Decodable { let status: WalletTradeStatus }
    let data = try await LocalBackendClient.get(path, query: query)
    return try JSONDecoder().decode(Status.self, from: data).status
  }

  private func save(_ updated: [WalletTradeActivity]) throws {
    try JSONEncoder().encode(updated).write(to: file, options: .atomic)
    entries = updated
  }
}
