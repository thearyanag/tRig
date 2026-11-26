import Testing

@testable import TradingWorkspace

private let triggerWallet = WalletAccount(family: .solana, address: "11111111111111111111111111111111")

@Test func jupiterLimitUsesExactSpendAndTheMarketMintForBothSides() throws {
  let asset = Asset.solana
  var limit = LimitOrderDraft()
  limit.setPrice("123.45")

  let buy = try #require(JupiterPriceOrderIntent(asset: asset,
    request: limit.request(asset: asset, trade: TradeDraft(side: .buy, amountText: "10.25")),
    account: triggerWallet))
  #expect(buy.inputMint == SwapQuoteInput.usdc)
  #expect(buy.inputAmount == "10250000")
  #expect(buy.outputMint == asset.id)
  #expect(buy.triggerMint == asset.id)
  #expect(buy.triggerCondition == .below)
  #expect(buy.triggerPriceUsd == "123.45")

  let sell = try #require(JupiterPriceOrderIntent(asset: asset,
    request: limit.request(asset: asset, trade: TradeDraft(side: .sell, amountText: "0.250000001")),
    account: triggerWallet))
  #expect(sell.inputMint == asset.id)
  #expect(sell.inputAmount == "250000001")
  #expect(sell.triggerCondition == .above)
}

@Test func jupiterExitPreservesEachLegQuantityAndRejectsFractionalBaseUnits() throws {
  let asset = Asset.solana
  var takeProfit = ExitLegDraft()
  takeProfit.target.setPrice("180")
  takeProfit.quantityText = "0.25"
  var stopLoss = ExitLegDraft()
  stopLoss.target.setPrice("90")
  stopLoss.quantityText = "0.5"

  let profit = try #require(JupiterPriceOrderIntent(asset: asset,
    request: takeProfit.request(kind: .takeProfit, asset: asset, slippage: .standard),
    account: triggerWallet))
  let stop = try #require(JupiterPriceOrderIntent(asset: asset,
    request: stopLoss.request(kind: .stopLoss, asset: asset, slippage: .standard),
    account: triggerWallet))
  #expect(profit.inputAmount == "250000000" && profit.triggerCondition == .above)
  #expect(stop.inputAmount == "500000000" && stop.triggerCondition == .below)

  stopLoss.quantityText = "0.5000000001"
  #expect(JupiterPriceOrderIntent(asset: asset,
    request: stopLoss.request(kind: .stopLoss, asset: asset, slippage: .standard),
    account: triggerWallet) == nil)
}
