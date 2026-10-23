import Foundation
import Testing

@testable import AccountWebTest

@Test func buyEstimateDeductsFeeAndAppliesSlippage() throws {
  let quote = try TradeDraft().preview(asset: .backpack, market: .backpack).get()
  #expect(quote.paySymbol == "USDC")
  #expect(quote.receiveSymbol == "BP")
  #expect(quote.feeUSDC == Decimal(string: "0.1"))
  #expect(quote.receiveAmount == Decimal(string: "237.857142"))
  #expect(quote.minimumReceive == Decimal(string: "236.667856"))
}

@Test func sellEstimateUsesAssetBalanceAndUSDCFee() throws {
  let quote = try TradeDraft(side: .sell, amountText: "100")
    .preview(asset: .backpack, market: .backpack).get()
  #expect(quote.paySymbol == "BP")
  #expect(quote.receiveSymbol == "USDC")
  #expect(quote.feeUSDC == Decimal(string: "0.042"))
  #expect(quote.receiveAmount == Decimal(string: "41.958"))
  #expect(quote.minimumReceive == Decimal(string: "41.74821"))
}

@Test(arguments: ["0", "-1", "1abc", "1e3", "1,000", "1.2.3", "NaN", "0.0000001", "."])
func malformedAmountsAreRejected(amount: String) {
  let result = TradeDraft(amountText: amount).preview(asset: .backpack, market: .backpack)
  if case .failure(let error) = result {
    #expect(error == .invalid)
  } else {
    Issue.record("Invalid input produced a trade preview")
  }
}

@Test func emptyAndInsufficientAmountsHaveDistinctStates() {
  let empty = TradeDraft(amountText: " ").preview(asset: .backpack, market: .backpack)
  if case .failure(let error) = empty {
    #expect(error == .empty)
  } else {
    Issue.record("Empty input produced a trade preview")
  }

  for draft in [TradeDraft(amountText: "1001"), TradeDraft(side: .sell, amountText: "251")] {
    if case .failure(let error) = draft.preview(asset: .backpack, market: .backpack) {
      #expect(error == .insufficient)
    } else {
      Issue.record("Over-balance input produced a trade preview")
    }
  }
}

@Test func maxBalancesRemainValidOnBothSides() throws {
  _ = try TradeDraft(amountText: "1000").preview(asset: .backpack, market: .backpack).get()
  _ = try TradeDraft(side: .sell, amountText: "250").preview(asset: .backpack, market: .backpack)
    .get()
}
