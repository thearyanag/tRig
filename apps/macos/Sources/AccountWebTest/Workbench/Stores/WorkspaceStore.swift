import Foundation
import Observation

protocol WorkspacePersistence {
  func read() -> Data?
  func write(_ data: Data)
}
struct PreferencesWorkspacePersistence: WorkspacePersistence {
  private let key = "workspace.watchlist.v1"
  func read() -> Data? { UserDefaults.standard.data(forKey: key) }
  func write(_ data: Data) { UserDefaults.standard.set(data, forKey: key) }
}

@MainActor @Observable
final class WorkspaceStore {
  static let shared = WorkspaceStore()
  private(set) var watchlist: [Asset]
  private(set) var selectedAsset: Asset
  private(set) var lastPrice: Double?
  private(set) var selectionVersion = 0
  @ObservationIgnored private let persistence: any WorkspacePersistence

  private struct Snapshot: Codable {
    let version: Int
    let watchlist: [Asset]
    let selectedAsset: Asset
  }

  init(persistence: any WorkspacePersistence = PreferencesWorkspacePersistence()) {
    self.persistence = persistence
    if let data = persistence.read(),
      let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
      saved.version == 1, saved.selectedAsset.isValid
    {
      var seen = Set<String>()
      watchlist = saved.watchlist.filter { $0.isValid && seen.insert($0.id).inserted }
      selectedAsset = saved.selectedAsset
    } else {
      watchlist = [.backpack]
      selectedAsset = .backpack
    }
  }

  func open(_ asset: Asset) {
    guard asset.isValid else { return }
    if selectedAsset.id == asset.id, selectedAsset.pool == asset.pool { return }
    lastPrice = nil
    selectedAsset = asset
    selectionVersion += 1
    save()
  }
  func openWatched(_ id: String) {
    if let asset = watchlist.first(where: { $0.id == id }) { open(asset) }
  }
  func isWatched(_ asset: Asset) -> Bool { watchlist.contains { $0.id == asset.id } }
  func toggleWatch(_ asset: Asset) {
    if isWatched(asset) {
      watchlist.removeAll { $0.id == asset.id }
    } else if asset.isValid {
      watchlist.append(asset)
    }
    save()
  }
  func applyResolved(_ asset: Asset) {
    guard asset.isValid, selectedAsset.id == asset.id else { return }
    if selectedAsset.pool != asset.pool { lastPrice = nil }
    selectedAsset = asset
    if let index = watchlist.firstIndex(where: { $0.id == asset.id }) { watchlist[index] = asset }
    save()
  }
  func receivePrice(_ price: Double, for asset: Asset) {
    guard selectedAsset.id == asset.id, selectedAsset.pool == asset.pool, price.isFinite, price > 0
    else { return }
    lastPrice = price
  }
  func step(_ offset: Int) {
    guard !watchlist.isEmpty else { return }
    if let index = watchlist.firstIndex(where: { $0.id == selectedAsset.id }) {
      open(watchlist[((index + offset) % watchlist.count + watchlist.count) % watchlist.count])
    } else {
      open(offset > 0 ? watchlist[0] : watchlist[watchlist.count - 1])
    }
  }
  private func save() {
    if let data = try? JSONEncoder().encode(
      Snapshot(version: 1, watchlist: watchlist, selectedAsset: selectedAsset))
    {
      persistence.write(data)
    }
  }
}
