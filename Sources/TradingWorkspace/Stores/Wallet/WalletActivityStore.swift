import Foundation
import Observation

@MainActor @Observable
final class WalletActivityStore {
  private(set) var entries: [WalletTransferActivity] = []
  private(set) var refreshing = false
  private let file: URL
  private let client = WalletTransferClient()
  private let loadFailure: Bool

  init(vault: WalletVault) {
    file = vault.url.deletingLastPathComponent().appending(path: "activity.json")
    do {
      entries = try JSONDecoder().decode([WalletTransferActivity].self, from: Data(contentsOf: file))
      loadFailure = false
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      loadFailure = false
    } catch {
      loadFailure = true
    }
  }

  func record(_ entry: WalletTransferActivity) throws {
    guard !loadFailure else { throw WalletFailure("Couldn’t open the wallet Activity file.") }
    guard !entries.contains(where: { $0.id == entry.id }) else {
      throw WalletFailure("This transfer is already in Activity.")
    }
    try save([entry] + entries)
  }

  func refresh() async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    let pending = Array(entries.filter { $0.status == .pending }.prefix(12))
    for item in pending {
      if Task.isCancelled { return }
      guard let value = try? await client.status(for: item), value != .pending,
        let index = entries.firstIndex(where: { $0.id == item.id })
      else { continue }
      var updated = entries
      updated[index].status = value
      try? save(updated)
    }
  }

  private func save(_ updated: [WalletTransferActivity]) throws {
    try JSONEncoder().encode(updated).write(to: file, options: .atomic)
    entries = updated
  }
}
