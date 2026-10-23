import Foundation

/// Explicitly attached public research only. Account credentials and balances have no representation here.
enum ResearchContext {
  static let postLimit = 10
  static let textLimit = 2500

  static func asset(_ asset: Asset) -> String {
    "Selected workspace asset: \(asset.name) (\(asset.symbol))\nChain: \(asset.network)\nContract: \(asset.id)\nThis selection alone is not evidence about current price or value."
  }

  static func pump(assetContext: String?, callouts: [PumpCallout]) -> String {
    let posts = callouts.prefix(postLimit).map {
      "Author: \($0.userName ?? $0.userId)\nCoin: \($0.coinMint)\nSource: \($0.link.absoluteString)\nPost: \(String(($0.thesis ?? "").prefix(textLimit)))"
    }
    return join([assetContext] + posts.map(Optional.some))
  }

  static func fomo(assetContext: String?, source: String, theses: [FomoThesis]) -> String {
    let posts = theses.prefix(postLimit).map {
      "Author: \($0.author)\nFomo thesis ID: \($0.id)\nPost: \(String($0.text.prefix(textLimit)))"
    }
    return join([assetContext, theses.isEmpty ? nil : source] + posts.map(Optional.some))
  }

  private static func join(_ parts: [String?]) -> String {
    parts.compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n\n")
  }
}
