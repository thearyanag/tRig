import Foundation
import PortfolioPulseSupport
import Testing
@testable import TradingWorkspace

private let midnight: Int64 = 1_800_057_600

private func fixture(cached: Bool = false, gap: Bool = false) throws -> PortfolioCache {
  let points: [[String: Any]] = [
    ["time": midnight - 600, "valueUsd": "90", "segment": 0],
    ["time": midnight + 600, "valueUsd": "110", "segment": 0],
    ["time": midnight + 1200, "valueUsd": "125", "segment": gap ? 1 : 0],
  ]
  let holdings: [[String: Any]] = [
    ["id": "sol", "chain": "solana", "mint": Asset.solana.id, "name": "Solana",
      "symbol": "SOL", "pnlUsd": "-38", "sources": [], "lots": [], "warnings": []],
    ["id": "bp", "chain": "solana", "mint": Asset.backpack.id, "name": "Backpack",
      "symbol": "BP", "pnlUsd": "17", "sources": [], "lots": [], "warnings": []],
  ]
  var summary: [String: Any] = [
    "scope": "all", "period": "1d", "totalValueUsd": "125",
    "sourceCount": 2, "asOf": midnight + 1200, "history": points,
    "holdings": holdings, "warnings": [],
  ]
  let all = summary
  summary["sourceCount"] = 1
  summary["totalValueUsd"] = "80"
  return try JSONDecoder().decode(PortfolioCache.self, from: JSONSerialization.data(withJSONObject: [
    "revision": 1, "accounts": [
      ["source": ConnectionService.pump.rawValue, "accountWallet": "pump"],
      ["source": ConnectionService.fomo.rawValue, "accountWallet": "fomo"],
    ],
    "views": ["all": all, "pump": summary, "fomo": summary], "market": all, "cached": cached,
  ]))
}

private var utc: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  return calendar
}

@Test func pulseComputesMoveBetweenComparableIntradayBalances() throws {
  #expect(Int64(utc.startOfDay(for: Date(timeIntervalSince1970: Double(midnight))).timeIntervalSince1970) == midnight)
  let result = try #require(PortfolioPulseSnapshot(cache: fixture(), calendar: utc))
  #expect(result.sources == "Pumpfun + Fomo")
  #expect(result.balance == 125)
  #expect(result.move == 25)
  #expect(result.movePercent == 25)
  #expect(result.history.flatMap { $0 }.map(\.value) == [110, 125])
  #expect(result.contributor?.symbol == "SOL")
  #expect(result.contributor?.amount == -38)
}

@Test func pulseOmitsUnreliableMovesAndCanUseASingleConfirmedSource() throws {
  #expect(try PortfolioPulseSnapshot(cache: fixture(cached: true), calendar: utc)?.move == nil)
  #expect(try PortfolioPulseSnapshot(cache: fixture(gap: true), calendar: utc)?.move == nil)
  let result = try #require(PortfolioPulseSnapshot(cache: fixture(), scope: .pump, calendar: utc))
  #expect(result.sources == "Pumpfun")
  #expect(result.balance == 80)
}

@Test func pulseStorageWritesAndClearsItsSummary() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let storage = PortfolioPulseStorage(url: directory.appendingPathComponent("pulse.json"))
  let result = try #require(PortfolioPulseSnapshot(cache: fixture(), calendar: utc))
  #expect(try storage.write(result))
  #expect(try storage.write(result) == false)
  #expect(storage.read() == result)
  #expect(try storage.write(nil))
  #expect(storage.read() == nil)
}
