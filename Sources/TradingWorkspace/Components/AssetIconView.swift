import AppKit
import SwiftUI

struct AssetIconView: View {
  let asset: Asset
  var size: CGFloat = 44

  var body: some View {
    Group {
      if asset.id == Asset.backpack.id,
        let url = Bundle.main.resourceURL?.appendingPathComponent("Icons/backpack.png"),
        let image = NSImage(contentsOf: url)
      {
        Image(nsImage: image).resizable().scaledToFit()
      } else if let address = asset.imageURL, let url = URL(string: address), url.scheme == "https"
      {
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
    .background(TerminalStyle.field, in: RoundedRectangle(cornerRadius: 6))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .accessibilityLabel("\(asset.name) token icon")
  }

  private var fallback: some View {
    Text(String(asset.symbol.prefix(2)))
      .font(AppTypography.font(size: size * 0.32, weight: .semibold))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
