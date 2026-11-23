import Foundation
import Testing

@testable import TradingWorkspace

@Test func inlineLimitRetainsTradingContextAndBuildsServerRoutedQuotes() {
  var limit = LimitOrderDraft()
  var trade = TradeDraft(amountText: " 100 ", slippage: .high)
  limit.setEnabled(true, reference: 0.4, side: .buy)
  #expect(limit.price == 0.38)
  let buy = limit.request(asset: .backpack, trade: trade)
  #expect(buy.isValid && buy.provider == nil && buy.orderType == .limit)
  #expect(buy.input.address == SwapQuoteInput.usdc)
  #expect(buy.output.address == Asset.backpack.id)
  #expect(buy.amount == "100" && buy.limitPriceUsd == "0.38")
  #expect(buy.slippageBps == 100)
  trade.selectQuoteSide(.sell)
  #expect(!limit.request(asset: .backpack, trade: trade).isValid)
  trade.amountText = "10"
  let sell = limit.request(asset: .backpack, trade: trade)
  #expect(sell.side == "sell" && sell.input.address == Asset.backpack.id)
  #expect(sell.output.address == SwapQuoteInput.usdc)
}

@Test func obsoleteChartEventsCannotChangeANewerOrHiddenDraft() {
  var limit = LimitOrderDraft()
  limit.setEnabled(true, reference: 1, side: .buy)
  let old = limit.revision
  limit.setPrice("0.8")
  limit.receiveChartPrice(0.7, revision: old)
  #expect(limit.priceText == "0.8")
  let current = limit.revision
  limit.receiveChartPrice(0.75, revision: current)
  #expect(limit.priceText == "0.75")
  let beforeDisable = limit.revision
  limit.setEnabled(false, reference: 1, side: .buy)
  limit.receiveChartPrice(0.5, revision: beforeDisable)
  #expect(limit.priceText == "0.75")
  #expect(limit.chartLine(asset: .backpack, side: .buy).price == nil)
}

@Test func removingDraftLineClearsPriceAndInvalidatesQuoteInput() {
  var limit = LimitOrderDraft()
  limit.setEnabled(true, reference: 1, side: .buy)
  limit.receiveChartPrice(nil, revision: limit.revision)
  #expect(limit.isEnabled && limit.priceText.isEmpty)
  #expect(!limit.request(asset: .backpack, trade: TradeDraft()).isValid)
  #expect(limit.chartLine(asset: .backpack, side: .buy).price == nil)
}

@Test func continuousChartMovementKeepsItsRevisionUntilANativeEdit() {
  var limit = LimitOrderDraft()
  limit.setEnabled(true, reference: 1, side: .buy)
  let dragRevision = limit.revision
  limit.receiveChartPrice(0.9, revision: dragRevision)
  limit.receiveChartPrice(0.8, revision: dragRevision)
  #expect(limit.priceText == "0.8")
  #expect(limit.revision == dragRevision)
  limit.setPrice("0.7")
  #expect(limit.revision != dragRevision)
  limit.receiveChartPrice(0.6, revision: dragRevision)
  #expect(limit.priceText == "0.7")
}

@Test func draftPricesRejectNonFiniteOrMalformedNumbersWithoutDrawing() {
  var limit = LimitOrderDraft()
  limit.setEnabled(true, reference: nil, side: .buy)
  for value in ["NaN", "inf", "1e3", "-1", "0", "1.2.3", "1,000"] {
    limit.setPrice(value)
    #expect(limit.price == nil)
    #expect(!limit.request(asset: .backpack, trade: TradeDraft()).isValid)
  }
  limit.setPrice("0.000000012345")
  #expect(limit.price != nil)
  #expect(LimitOrderDraft.formatted(0.000000012345) == "0.000000012345")
  #expect(!LimitOrderDraft.formatted(100000).contains(","))
}
