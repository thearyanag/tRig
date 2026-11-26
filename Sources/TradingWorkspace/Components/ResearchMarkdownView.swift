import MarkdownUI
import SwiftUI

struct ResearchMarkdownView: View {
  let text: String

  var body: some View {
    Markdown(text)
      .markdownSoftBreakMode(.lineBreak)
      .markdownTextStyle {
        FontFamily(.custom("Allo-Regular"))
        ForegroundColor(.primary)
      }
      .markdownTextStyle(\.strong) {
        FontFamily(.custom("Allo-Bold"))
      }
      .markdownTextStyle(\.link) {
        ForegroundColor(.accentColor)
        UnderlineStyle(.single)
      }
      .markdownImageProvider(ResearchImagePlaceholder())
      .markdownInlineImageProvider(ResearchImagePlaceholder())
      .environment(\.openURL, OpenURLAction { url in
        if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil {
          return .systemAction
        }
        return .discarded
      })
  }
}

private struct ResearchImagePlaceholder: ImageProvider, InlineImageProvider {
  func makeImage(url: URL?) -> some View {
    Image(systemName: "photo").foregroundStyle(.secondary).accessibilityLabel("Image")
  }

  func image(with url: URL, label: String) async throws -> Image {
    Image(systemName: "photo")
  }
}
