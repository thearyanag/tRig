import Foundation
import Testing

@testable import AccountWebTest

struct ResearchContextTests {
  @Test func noPostsAndNoAssetMeansNoAttachment() {
    #expect(ResearchContext.pump(assetContext: nil, callouts: []) == "")
    #expect(ResearchContext.fomo(assetContext: nil, source: "previous trade", theses: []) == "")
  }

  @Test func assetContextDoesNotInventCurrentPrices() {
    let text = ResearchContext.asset(.backpack)
    #expect(text.contains(Asset.backpack.id))
    #expect(text.contains("Chain: Solana"))
    #expect(text.contains("not evidence about current price"))
  }

  @Test func fomoKeepsThePostSourceDistinctFromTheSelectedAsset() {
    let post = FomoThesis(id: "fixture", author: "example", text: "A thesis about another asset")
    let text = ResearchContext.fomo(
      assetContext: "Selected asset A", source: "Fomo source: token B", theses: [post])
    #expect(text.contains("Selected asset A\n\nFomo source: token B"))
    #expect(text.contains("Fomo thesis ID: fixture"))
  }

  @Test func attachmentsBoundBothPostCountAndText() {
    let posts = (0..<12).map {
      FomoThesis(id: "post-\($0)", author: "example", text: String(repeating: "x", count: 3000))
    }
    let text = ResearchContext.fomo(assetContext: nil, source: "source", theses: posts)
    #expect(text.components(separatedBy: "Fomo thesis ID:").count - 1 == 10)
    #expect(!text.contains("post-10"))
    #expect(!text.contains(String(repeating: "x", count: 2501)))
  }
}
