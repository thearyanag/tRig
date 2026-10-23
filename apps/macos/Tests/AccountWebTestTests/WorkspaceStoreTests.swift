import Foundation
import Testing

@testable import AccountWebTest

private final class MemoryWorkspacePersistence: WorkspacePersistence {
  var data: Data?
  func read() -> Data? { data }
  func write(_ data: Data) { self.data = data }
}
private let sol = Asset(
  id: "So11111111111111111111111111111111111111112", name: "Wrapped SOL", symbol: "SOL",
  network: "Solana", pool: Asset.backpack.pool, decimals: 9, priceUsd: 120
)

@Test @MainActor func watchlistAndSelectionSurviveRestorationWithoutAPrice() {
  let storage = MemoryWorkspacePersistence()
  let store = WorkspaceStore(persistence: storage)
  store.toggleWatch(sol)
  store.open(sol)
  store.receivePrice(123, for: sol)
  let restored = WorkspaceStore(persistence: storage)
  #expect(restored.watchlist.map(\.id) == [Asset.backpack.id, sol.id])
  #expect(restored.selectedAsset.id == sol.id)
  #expect(restored.lastPrice == nil)
}

@Test @MainActor func oldAssetResponsesCannotOverwriteTheNewSelection() {
  let store = WorkspaceStore(persistence: MemoryWorkspacePersistence())
  store.receivePrice(1.2, for: .backpack)
  store.open(sol)
  #expect(store.lastPrice == nil)
  store.receivePrice(99, for: .backpack)
  store.applyResolved(.backpack)
  #expect(store.selectedAsset.id == sol.id)
  #expect(store.lastPrice == nil)
  store.receivePrice(120, for: sol)
  #expect(store.lastPrice == 120)
}

@Test @MainActor func watchRemovalDoesNotCloseTheAssetAndNavigationWraps() {
  let store = WorkspaceStore(persistence: MemoryWorkspacePersistence())
  store.toggleWatch(sol)
  store.open(sol)
  store.step(1)
  #expect(store.selectedAsset.id == Asset.backpack.id)
  store.step(-1)
  #expect(store.selectedAsset.id == sol.id)
  store.toggleWatch(sol)
  #expect(store.selectedAsset.id == sol.id)
  #expect(!store.isWatched(sol))
  store.toggleWatch(sol)
  #expect(store.watchlist.filter { $0.id == sol.id }.count == 1)
}

@Test @MainActor func corruptSavedStateFallsBackSafely() {
  let storage = MemoryWorkspacePersistence()
  storage.data = Data("not json".utf8)
  let store = WorkspaceStore(persistence: storage)
  #expect(store.selectedAsset == .backpack)
  #expect(store.watchlist == [.backpack])
}
