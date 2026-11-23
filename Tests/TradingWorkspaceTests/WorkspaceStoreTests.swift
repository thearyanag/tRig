import Foundation
import Testing

@testable import TradingWorkspace

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
  store.toggleWatch(.backpack)
  store.open(.backpack)
  store.receivePrice(1.2, for: .backpack)
  let restored = WorkspaceStore(persistence: storage)
  #expect(restored.watchlist.map(\.id) == [sol.id, Asset.backpack.id])
  #expect(restored.selectedAsset == .backpack)
  #expect(restored.lastPrice == nil)
}

@Test @MainActor func oldAssetResponsesCannotOverwriteTheNewSelection() {
  let store = WorkspaceStore(persistence: MemoryWorkspacePersistence())
  store.open(.backpack)
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
  store.toggleWatch(.backpack)
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
  #expect(store.selectedAsset == .solana)
  #expect(store.watchlist == [.solana])
}

@Test @MainActor func freshWorkspaceStartsOnSolanaWithoutInventingAPool() {
  let store = WorkspaceStore(persistence: MemoryWorkspacePersistence())
  #expect(store.selectedAsset.identity == "solana:\(sol.id)")
  #expect(store.selectedAsset.symbol == "SOL")
  #expect(store.selectedAsset.isValid)
  #expect(store.selectedAsset.pool.isEmpty)
  #expect(store.isWatched(.solana))
}

@Test @MainActor func identicalEVMAddressesOnDifferentChainsStaySeparate() {
  let storage = MemoryWorkspacePersistence()
  let store = WorkspaceStore(persistence: storage)
  let a = Asset(
    id: "0x1111111111111111111111111111111111111111", name: "Token", symbol: "TOK",
    network: "Base", pool: "", decimals: 18, priceUsd: nil, chainId: "eip155:8453")
  let b = Asset(id: a.id, name: a.name, symbol: a.symbol, network: "Ethereum",
    pool: "", decimals: 18, priceUsd: nil, chainId: "eip155:1")
  store.toggleWatch(a)
  store.toggleWatch(b)
  #expect(store.isWatched(a) && store.isWatched(b))
  store.open(a)
  store.receivePrice(10, for: b)
  #expect(store.lastPrice == nil)
  store.receivePrice(5, for: a)
  #expect(store.lastPrice == 5)
  store.toggleWatch(a)
  #expect(!store.isWatched(a) && store.isWatched(b))
  let restored = WorkspaceStore(persistence: storage)
  #expect(restored.selectedAsset.identity == a.identity)
  #expect(restored.isWatched(b))
}
