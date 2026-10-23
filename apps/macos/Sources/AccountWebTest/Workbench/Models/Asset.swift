import Foundation

struct Asset: Identifiable, Hashable, Codable, Sendable {
  let id: String
  let name: String
  let symbol: String
  let network: String
  let pool: String
  let decimals: Int?
  let priceUsd: Double?

  var shortAddress: String { "\(id.prefix(4))…\(id.suffix(4))" }
  var isValid: Bool {
    network == "Solana" && (32...44).contains(id.count) && (32...44).contains(pool.count)
      && !name.isEmpty && !symbol.isEmpty && (decimals == nil || (0...255).contains(decimals!))
      && (priceUsd == nil || (priceUsd!.isFinite && priceUsd! > 0))
  }
  var systemImage: String { id == Self.backpack.id ? "backpack.fill" : "circle.hexagongrid.fill" }

  static let backpack = Asset(
    id: "BPxxfRCXkUVhig4HS1Lh7kZqV6SPJhzfEk4x6fVBjPCy",
    name: "Backpack", symbol: "BP", network: "Solana",
    pool: "6qz7THwQvcjF3HyDGLuKaLBUk6EyJKeZXZMWLAeiwfjd", decimals: 9, priceUsd: nil
  )
}
