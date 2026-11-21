import Foundation
import Testing

@testable import TradingWorkspace

@Test func olderSavedAssetsDecodeWithoutArtworkOrVolume() throws {
  let encoded = try JSONEncoder().encode(Asset.backpack)
  var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  object.removeValue(forKey: "imageURL")
  object.removeValue(forKey: "volume24h")
  let restored = try JSONDecoder().decode(
    Asset.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(restored.id == Asset.backpack.id)
  #expect(restored.imageURL == nil)
  #expect(restored.volume24h == nil)
}

@Test func quoteOnlyEVMAssetsRemainValidWithoutAChart() {
  var a = Asset(
    id: "0x1111111111111111111111111111111111111111", name: "Token", symbol: "TOK",
    network: "Base", pool: "", decimals: 18, priceUsd: nil, chainId: "eip155:8453",
    explorerUrl: "https://basescan.org",
    quoteToken: .init(
      address: "0x2222222222222222222222222222222222222222", symbol: "USDC", name: "USD Coin",
      decimals: 6),
    marketQuotes: true, conditionalQuotes: true)
  #expect(a.isValid && !a.hasChart)
  #expect(a.tokenExplorer?.host == "basescan.org")
  var limit = LimitOrderDraft()
  limit.setEnabled(true, reference: 1, side: .buy)
  let r = limit.request(asset: a, trade: TradeDraft())
  #expect(r.input.chain == "eip155:8453" && r.output.chain == "eip155:8453")
  #expect(r.input.address == a.quoteToken?.address && r.input.address != SwapQuoteInput.usdc)
  a.chainId = "solana"
  #expect(!a.isValid)
  a.chainId = "eip155:8453"
  a.explorerUrl = "javascript:alert(1)"
  #expect(a.tokenExplorer == nil)
}
