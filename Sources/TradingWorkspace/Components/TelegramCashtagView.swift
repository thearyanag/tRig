import SwiftUI

struct TelegramCashtagView: View {
  let asset: Asset

  var body: some View {
    HStack(spacing: 4) {
      AssetIconView(asset: asset, size: 13).accessibilityHidden(true)
      Text(verbatim: "$" + asset.symbol).font(AppTypography.caption)
        .fontWeight(.medium).lineLimit(1)
        .foregroundStyle(.blue)
    }
    .padding(.horizontal, 5).padding(.vertical, 2)
    .background(TerminalStyle.field, in: RoundedRectangle(cornerRadius: 4))
    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(TerminalStyle.border))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("$" + asset.symbol)
    .help(asset.name)
  }
}

struct TelegramQuoteBody: View {
  let quote: TelegramQuote
  let asset: Asset

  var body: some View {
    if quote.parts.contains(.cashtag) {
      TelegramInlineLayout {
        ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
          Group {
            if let text = run.text {
              Text(verbatim: text).font(AppTypography.callout)
            } else {
              TelegramCashtagView(asset: asset)
            }
          }
          .layoutValue(key: TelegramInlineGap.self, value: run.gap)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: quote.parts.map { part in
        switch part {
        case .text(let text): text
        case .cashtag: "$" + asset.symbol
        }
      }.joined()))
    } else {
      Text(verbatim: quote.prose).font(AppTypography.callout).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private struct Run {
    let text: String?
    let gap: CGFloat
  }

  private var runs: [Run] {
    var result: [Run] = []
    var gap: CGFloat = 0
    for part in quote.parts {
      switch part {
      case .cashtag:
        result.append(Run(text: nil, gap: gap))
        gap = 0
      case .text(let text):
        var word = ""
        for character in text {
          if character.isWhitespace {
            if !word.isEmpty {
              result.append(Run(text: word, gap: gap))
              word = ""
            }
            gap = 3
          } else {
            word.append(character)
          }
        }
        if !word.isEmpty {
          result.append(Run(text: word, gap: gap))
          gap = 0
        }
      }
    }
    return result
  }
}

private struct TelegramInlineGap: LayoutValueKey {
  static let defaultValue: CGFloat = 0
}

/// Keep a token chip together when it wraps, while leaving punctuation attached
/// to its neighboring text. Measure long individual runs at the sidebar width.
private struct TelegramInlineLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(width: proposal.width ?? .infinity, subviews: subviews).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
    cache: inout ()
  ) {
    let placements = arrange(width: bounds.width, subviews: subviews).placements
    for (view, box) in zip(subviews, placements) {
      view.place(at: CGPoint(x: bounds.minX + box.minX, y: bounds.minY + box.minY),
        anchor: .topLeading, proposal: ProposedViewSize(box.size))
    }
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, placements: [CGRect]) {
    var placements: [CGRect] = []
    var row: [Int] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var height: CGFloat = 0
    var longest: CGFloat = 0

    func finishRow() {
      for index in row {
        placements[index].origin.y = y + (height - placements[index].height) / 2
      }
      longest = max(longest, x)
      y += height + 3
      x = 0
      height = 0
      row.removeAll(keepingCapacity: true)
    }

    for view in subviews {
      let ideal = view.sizeThatFits(.unspecified)
      let size = ideal.width > width
        ? view.sizeThatFits(ProposedViewSize(width: width, height: nil))
        : ideal
      let preferredGap = view[TelegramInlineGap.self]
      if !row.isEmpty && x + preferredGap + size.width > width { finishRow() }
      if !row.isEmpty { x += preferredGap }
      row.append(placements.count)
      placements.append(CGRect(x: x, y: y, width: size.width, height: size.height))
      x += size.width
      height = max(height, size.height)
    }
    if !row.isEmpty { finishRow() }
    return (CGSize(width: longest, height: max(0, y - 3)), placements)
  }
}
