import Foundation

enum WorkspaceSection: String, CaseIterable, Identifiable {
  case markets = "Markets"
  case portfolio = "Portfolio"
  var id: Self { self }
}
enum PortfolioScope: String, CaseIterable, Identifiable {
  case all, pump, fomo, wallet
  var id: Self { self }
  var name: String {
    switch self {
    case .all: "All accounts"
    case .pump: "Pumpfun"
    case .fomo: "Fomo"
    case .wallet: "tRig wallet"
    }
  }
}
enum PortfolioPeriod: String, CaseIterable, Identifiable, Codable, Sendable {
  case day = "1d"
  case week = "7d"
  case month = "30d"
  case all
  var id: Self { self }
  var name: String {
    switch self {
    case .day: "24h"
    case .week: "7d"
    case .month: "30d"
    case .all: "All"
    }
  }
  var pumpPeriod: String { self == .week ? "1w" : self == .month ? "1m" : rawValue }
}
enum PortfolioSort: String, CaseIterable, Identifiable {
  case valueDescending = "Value ↓"
  case valueAscending = "Value ↑"
  case asset = "Asset A–Z"
  case pnl = "P&L ↓"
  var id: Self { self }
}
struct PortfolioViews: Decodable, Sendable {
  let all: PortfolioSnapshot
  let pump: PortfolioSnapshot
  let fomo: PortfolioSnapshot
  func view(_ scope: PortfolioScope) -> PortfolioSnapshot? {
    switch scope {
    case .all: all
    case .pump: pump
    case .fomo: fomo
    case .wallet: nil
    }
  }
}
struct PortfolioSnapshot: Decodable, Sendable {
  let scope: String
  let period: PortfolioPeriod
  let totalValueUsd: String?
  let periodPnlUsd: String?
  let periodPnlPercent: String?
  let unrealizedPnlUsd: String?
  let unrealizedPnlPercent: String?
  let holdings: [PortfolioHolding]
  let history: [PortfolioHistoryPoint]
  let sourceCount: Int
  let asOf: Double?
  let warnings: [String]
  let historyMessage: String?
}
enum PortfolioHoldingSource: String, Decodable, CaseIterable, Sendable {
  case pump, fomo, wallet

  var name: String {
    switch self {
    case .pump: "Pumpfun"
    case .fomo: "Fomo"
    case .wallet: "tRig wallet"
    }
  }
}
struct PortfolioHolding: Decodable, Identifiable, Sendable {
  let id: String
  let chain: String
  let mint: String
  let marketMint: String?
  let name: String
  let symbol: String
  let imageUrl: String?
  let quantity: String?
  let priceUsd: String?
  let valueUsd: String?
  let averageEntryUsd: String?
  let pnlUsd: String?
  let pnlPercent: String?
  let sources: [PortfolioHoldingSource]
  let lots: [PortfolioLot]
  let warnings: [String]
}
struct PortfolioLot: Decodable, Identifiable, Sendable {
  let id: String
  let chain: String
  let mint: String
  let wallet: String
  let name: String
  let symbol: String
  let imageUrl: String?
  let quantity: String?
  let priceUsd: String?
  let valueUsd: String?
  let costBasisUsd: String?
  let averageEntryUsd: String?
  let pnlPercent: String?
  let pnlUsd: String?
  let sources: [PortfolioHoldingSource]
  let warnings: [String]
  let fetchedAt: Double
}
struct PortfolioHistoryPoint: Decodable, Identifiable, Sendable {
  let time: Int64
  let valueUsd: String
  let segment: Int
  var id: Int64 { time }
  var date: Date { Date(timeIntervalSince1970: Double(time)) }
}
struct PortfolioProviderPayload: Sendable {
  let source: ConnectionService
  let wallet: String
  let period: PortfolioPeriod
  let data: Data
  let fetchedAt: Date
  var stale = false

  func requestObject() throws -> [String: Any] {
    var value = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    value["source"] = source.rawValue
    value["accountWallet"] = wallet
    value["period"] = period.rawValue
    value["fetchedAt"] = fetchedAt.timeIntervalSince1970
    value["stale"] = stale
    return value
  }
}
struct PortfolioReadFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
