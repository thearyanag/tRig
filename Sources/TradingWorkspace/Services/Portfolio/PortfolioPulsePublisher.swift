import Foundation
import OSLog
import PortfolioPulseSupport
import WidgetKit

@MainActor
struct PortfolioPulsePublisher {
  let storage: PortfolioPulseStorage
  private let logger = Logger(subsystem: "com.aryan.TradingWorkspace", category: "PortfolioPulse")

  func publish(_ snapshot: PortfolioPulseSnapshot?) {
    do {
      if try storage.write(snapshot) {
        WidgetCenter.shared.reloadTimelines(ofKind: PortfolioPulseSnapshot.kind)
      }
    } catch {
      logger.error("Could not update the portfolio widget snapshot.")
    }
  }
}

extension PortfolioPulseSnapshot {
  init?(cache: PortfolioCache, scope: PortfolioScope = .all, calendar: Calendar = .autoupdatingCurrent) {
    guard let view = cache.views.view(scope) else { return nil }
    let accounts = cache.accounts.filter {
      scope == .all || $0.source == (scope == .pump ? .pump : .fomo)
    }
    guard view.period == .day, view.sourceCount == accounts.count,
      let balance = PortfolioFormat.decimal(view.totalValueUsd),
      let timestamp = view.asOf, timestamp.isFinite, timestamp > 0
    else { return nil }

    let updatedAt = Date(timeIntervalSince1970: timestamp)
    let start = calendar.startOfDay(for: updatedAt)
    let validPoints = view.history.filter {
      $0.date <= updatedAt && PortfolioFormat.decimal($0.valueUsd) != nil
    }
    let today = validPoints.filter { $0.date >= start }
    let grouped = Dictionary(grouping: today, by: \.segment)
    let history: [[Point]] = grouped.keys.sorted().suffix(6).compactMap { segment in
      guard let points = grouped[segment], points.count > 1 else { return nil }
      let count = min(points.count, 48)
      return (0..<count).compactMap { index in
        let point = points[index * (points.count - 1) / (count - 1)]
        guard let value = Double(point.valueUsd), value.isFinite else { return nil }
        return Point(date: point.date, value: value)
      }
    }

    // Compare fresh portfolio history across local midnight within the same segment.
    let opening = cache.cached ? nil : Self.openingValue(validPoints, at: start)
    let close = today.last.flatMap { point in
      point.segment == opening?.segment ? PortfolioFormat.decimal(point.valueUsd) : nil
    }
    let move = close.flatMap { close in opening.map { close - $0.amount } }
    let percent = move.flatMap { move in
      opening.flatMap { $0.amount > 0 ? 100 * move / $0.amount : nil }
    }
    let contributor = view.holdings.compactMap { holding -> Contributor? in
      guard let amount = PortfolioFormat.decimal(holding.pnlUsd), amount != 0 else { return nil }
      let icon: String?
      switch (holding.chain, holding.mint) {
      case ("solana", Asset.solana.id), ("solana", "native:solana"): icon = "solana"
      case ("solana", Asset.backpack.id): icon = "backpack"
      case ("solana", SwapQuoteInput.usdc): icon = "usdc"
      default: icon = nil
      }
      return Contributor(symbol: String(holding.symbol.prefix(12)), amount: amount, icon: icon)
    }.max { abs($0.amount) < abs($1.amount) }
    let sources = [ConnectionService.pump, .fomo].filter { source in
      accounts.contains { $0.source == source }
    }.map(\.name).joined(separator: " + ")
    guard !sources.isEmpty else { return nil }
    self.init(
      sources: sources, balance: balance, move: move, movePercent: percent,
      history: history, contributor: contributor, updatedAt: updatedAt)
  }

  private static func openingValue(
    _ points: [PortfolioHistoryPoint], at start: Date
  ) -> (amount: Decimal, segment: Int)? {
    guard let after = points.first(where: { $0.date >= start }),
      let right = PortfolioFormat.decimal(after.valueUsd)
    else { return nil }
    if after.date == start { return (right, after.segment) }
    guard let before = points.last(where: { $0.date < start }), before.segment == after.segment,
      let left = PortfolioFormat.decimal(before.valueUsd)
    else { return nil }
    let span = after.time - before.time
    guard span > 0, span <= 3_600 else { return nil }
    let fraction = Decimal(start.timeIntervalSince1970 - Double(before.time)) / Decimal(span)
    return (left + (right - left) * fraction, after.segment)
  }
}
