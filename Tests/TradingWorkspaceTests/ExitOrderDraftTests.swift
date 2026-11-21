import Foundation
import Testing

@testable import TradingWorkspace

@Test func exitPreviewsUseSeparateTokenQuantitiesAndCorrectConditionalContracts() {
  var exits = ExitOrderDraft()
  exits.setEnabled(true, reference: 1)
  #expect(exits.takeProfit.target.price == 1.1)
  #expect(exits.stopLoss.target.price == 0.9)
  #expect(exits.takeProfit.quantityText.isEmpty && exits.stopLoss.quantityText.isEmpty)
  exits.takeProfit.quantityText = "10"
  exits.stopLoss.quantityText = "25"
  let tp = exits.takeProfit.request(kind: .takeProfit, asset: .backpack, slippage: .standard)
  let sl = exits.stopLoss.request(kind: .stopLoss, asset: .backpack, slippage: .standard)
  #expect(tp.isValid && sl.isValid)
  #expect(tp.side == "sell" && sl.side == "sell")
  #expect(tp.input.address == Asset.backpack.id && sl.input.address == Asset.backpack.id)
  #expect(tp.output.address == SwapQuoteInput.usdc && sl.output.address == SwapQuoteInput.usdc)
  #expect(tp.amount == "10" && sl.amount == "25")
  #expect(tp.orderType == .limit && tp.limitPriceUsd == "1.1" && tp.triggerPriceUsd == nil)
  #expect(sl.orderType == .stopLoss && sl.triggerPriceUsd == "0.9" && sl.limitPriceUsd == nil)
  #expect(tp.context.sender == nil && sl.context.sender == nil)
}

@Test func exitChartEventsCannotCrossLegsOrSurviveModeChanges() {
  var exits = ExitOrderDraft()
  exits.setEnabled(true, reference: 1)
  let lines = exits.chartLines(asset: .backpack)
  #expect(lines.map(\.id) == ["take-profit", "stop-loss"])
  let tpRevision = exits.takeProfit.target.revision
  let slRevision = exits.stopLoss.target.revision
  exits.receiveChartPrice(id: "stop-loss", value: 0.8, revision: tpRevision)
  #expect(exits.stopLoss.target.price == 0.9)
  exits.receiveChartPrice(id: "take-profit", value: 1.2, revision: tpRevision)
  #expect(exits.takeProfit.target.price == 1.2 && exits.stopLoss.target.price == 0.9)
  #expect(exits.stopLoss.target.revision == slRevision)
  exits.receiveChartPrice(id: "take-profit", value: nil, revision: tpRevision)
  #expect(exits.takeProfit.target.price == nil && exits.stopLoss.target.price == 0.9)
  exits.setEnabled(false, reference: 1)
  #expect(exits.chartLines(asset: .backpack).isEmpty)
  exits.setEnabled(true, reference: 1)
  exits.receiveChartPrice(id: "stop-loss", value: 0.5, revision: slRevision)
  #expect(exits.stopLoss.target.price == 0.9)
}

@Test func exitTargetsValidateDirectionWithoutChangingTheOtherLeg() {
  var exits = ExitOrderDraft()
  exits.setEnabled(true, reference: 1)
  #expect(exits.takeProfit.validation(kind: .takeProfit, reference: 1) == nil)
  #expect(exits.stopLoss.validation(kind: .stopLoss, reference: 1) == nil)
  exits.takeProfit.target.setPrice("0.8")
  #expect(exits.takeProfit.validation(kind: .takeProfit, reference: 1) != nil)
  #expect(exits.stopLoss.validation(kind: .stopLoss, reference: 1) == nil)
  exits.stopLoss.target.setPrice("1.2")
  #expect(exits.stopLoss.validation(kind: .stopLoss, reference: 1) != nil)
  exits.takeProfit.setEnabled(false, kind: .takeProfit, reference: 1)
  #expect(exits.chartLines(asset: .backpack).map(\.id) == ["stop-loss"])
  #expect(exits.stopLoss.target.price == 1.2)
}
