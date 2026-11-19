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
