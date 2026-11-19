import Foundation

extension TradeDraft {
  mutating func selectQuoteSide(_ side: TradeSide) {
    guard self.side != side else { return }
    self.side = side
    // Amounts have different token units on each side.
    amountText = ""
  }

  mutating func reverseQuote(asset: Asset, quote: SwapQuote?, at date: Date) {
    let current = SwapQuoteInput(asset: asset, draft: self)
    let amount = quote.flatMap {
      $0.matches(current) && $0.isFresh(at: date) ? $0.receiveAmount : nil
    }
    side = side == .buy ? .sell : .buy
    amountText = amount ?? ""
  }
}
