import Foundation
import Testing

@testable import TradingWorkspace

@Test func portfolioPeriodsMapToEachProvidersContract() {
  #expect(PortfolioPeriod.day.pumpPeriod == "1d")
  #expect(PortfolioPeriod.week.pumpPeriod == "1w")
  #expect(PortfolioPeriod.month.pumpPeriod == "1m")
  #expect(PortfolioPeriod.all.pumpPeriod == "all")
}

@Test func portfolioFormattingPreservesUnknownAndTinyNonzeroValues() {
  #expect(PortfolioFormat.currency(nil) == "—")
  #expect(PortfolioFormat.currency("0") == "$0.00")
  #expect(PortfolioFormat.currency("0.00004") == "<$0.01")
  #expect(PortfolioFormat.currency("-0.00004", signed: true) == "−<$0.01")
  #expect(PortfolioFormat.quantity("9007199254740993") == "9,007,199,254,740,993")
  #expect(PortfolioFormat.quantity("0.0000000000000000001") == "<0.000000000000000001")
  #expect(PortfolioFormat.percent(nil) == nil)
}

@Test func portfolioPayloadBindsSourceWalletAndPeriodAtTheNativeBoundary() throws {
  let payload = PortfolioProviderPayload(
    source: .fomo, wallet: "expected-wallet", period: .week,
    data: Data(
      #"{"source":"pump","accountWallet":"wrong-wallet","period":"all","data":{"balances":{}}}"#
        .utf8),
    fetchedAt: Date(timeIntervalSince1970: 123), stale: true)
  let object = try payload.requestObject()
  #expect(object["source"] as? String == "fomo")
  #expect(object["accountWallet"] as? String == "expected-wallet")
  #expect(object["period"] as? String == "7d")
  #expect(object["fetchedAt"] as? Double == 123)
  #expect(object["stale"] as? Bool == true)
}
