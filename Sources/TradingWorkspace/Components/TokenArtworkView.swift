import AppKit
import SwiftUI

struct TokenArtworkView: View {
  let mint: String
  let name: String
  let symbol: String
  let imageURL: String?
  var size: CGFloat = 28
  private var bundled: String? {
    if mint == Asset.backpack.id { return "backpack.png" }
    if mint == SwapQuoteInput.usdc { return "usdc.png" }
    if mint == "native:solana" || mint == "So11111111111111111111111111111111111111112" {
      return "solana.jpg"
    }
    return nil
  }
  var body: some View {
    Group {
      if let bundled, let url = Bundle.main.resourceURL?.appendingPathComponent("Icons/\(bundled)"),
        let icon = NSImage(contentsOf: url)
      {
        Image(nsImage: icon).resizable().scaledToFit()
      } else if let imageURL, let url = URL(string: imageURL), url.scheme == "https" {
        AsyncImage(url: url) { image in
          image.resizable().scaledToFit()
        } placeholder: {
          fallback
        }
      } else {
        fallback
      }
    }
    .frame(width: size, height: size)
    .background(TerminalStyle.field, in: RoundedRectangle(cornerRadius: 4))
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityLabel("\(name) token icon")
  }
  private var fallback: some View {
    Image(systemName: "circle.hexagongrid.fill").resizable().scaledToFit()
      .foregroundStyle(.secondary).padding(size * 0.15)
  }
}
