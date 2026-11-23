import Foundation

struct Asset: Identifiable, Hashable, Codable, Sendable {
  let id: String
  let name: String
  let symbol: String
  let network: String
  let pool: String
  let decimals: Int?
  let priceUsd: Double?
  var imageURL: String? = nil
  var volume24h: Double? = nil
  var chainId: String? = nil
  var marketNetwork: String? = nil
  var explorerUrl: String? = nil
  var change24h: Double? = nil
  var liquidityUsd: Double? = nil
  var marketCapUsd: Double? = nil
  var fdvUsd: Double? = nil
  var quoteToken: MarketCurrency? = nil
  var marketQuotes: Bool? = nil
  var conditionalQuotes: Bool? = nil
  var marketResolved: Bool? = nil
  var marketRouteVersion: Int? = nil

  var chainID: String { chainId ?? "solana" }
  var isSolana: Bool { chainID == "solana" }
  var identity: String { chainID + ":" + (isSolana ? id : id.lowercased()) }
  var marketKey: String { identity + ":" + (isSolana ? pool : pool.lowercased()) }
  var hasChart: Bool { !pool.isEmpty && (isSolana || marketNetwork != nil) }
  var supportsConditions: Bool { conditionalQuotes ?? isSolana }
  var settlement: MarketCurrency? {
    if isSolana { return .usdc }
    return quoteToken
  }
  var settlementAsset: Asset? {
    settlement.map {
      Asset(
        id: $0.address, name: $0.name, symbol: $0.symbol, network: network,
        pool: "", decimals: $0.decimals, priceUsd: nil, imageURL: $0.imageUrl, chainId: chainID)
    }
  }
  var explorer: URL? {
    guard let raw = explorerUrl ?? (isSolana ? "https://solscan.io" : nil),
      let url = URL(string: raw), url.scheme == "https"
    else { return nil }
    return url
  }
  var tokenExplorer: URL? { explorer?.appendingPathComponent("token").appendingPathComponent(id) }
  func transactionExplorer(_ hash: String) -> URL? {
    explorer?.appendingPathComponent("tx").appendingPathComponent(hash)
  }

  var shortAddress: String { "\(id.prefix(4))…\(id.suffix(4))" }
  var isValid: Bool {
    Self.validAddress(id, chain: chainID)
      && (pool.isEmpty
        || (isSolana
          ? (32...44).contains(pool.count)
          : [42, 66].contains(pool.count) && pool.hasPrefix("0x")
            && pool.dropFirst(2).allSatisfy(\.isHexDigit)))
      && !name.isEmpty && !symbol.isEmpty && (decimals == nil || (0...255).contains(decimals!))
      && (priceUsd == nil || (priceUsd!.isFinite && priceUsd! > 0))
  }
  static func validAddress(_ value: String, chain: String) -> Bool {
    if chain == "solana" {
      return (32...44).contains(value.count)
        && value.allSatisfy {
          "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".contains($0)
        }
    }
    return chain.hasPrefix("eip155:") && UInt64(chain.dropFirst(7)).map { $0 > 0 } == true
      && value.count == 42 && value.hasPrefix("0x") && value.dropFirst(2).allSatisfy(\.isHexDigit)
  }
  // Resolve the current SOL market on first open rather than seeding an old pool or price.
  static let solana = Asset(
    id: "So11111111111111111111111111111111111111112",
    name: "Solana", symbol: "SOL", network: "Solana", pool: "", decimals: 9, priceUsd: nil
  )

  static let backpack = Asset(
    id: "BPxxfRCXkUVhig4HS1Lh7kZqV6SPJhzfEk4x6fVBjPCy",
    name: "Backpack", symbol: "BP", network: "Solana",
    pool: "6qz7THwQvcjF3HyDGLuKaLBUk6EyJKeZXZMWLAeiwfjd", decimals: 9, priceUsd: nil
  )
}

struct MarketCurrency: Codable, Hashable, Sendable {
  let address: String
  let symbol: String
  let name: String
  let decimals: Int?
  var imageUrl: String? = nil
  static let usdc = MarketCurrency(
    address: SwapQuoteInput.usdc, symbol: "USDC", name: "USD Coin", decimals: 6)
}
