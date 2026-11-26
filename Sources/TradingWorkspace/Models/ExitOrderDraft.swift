import Foundation

enum ExitLegKind: String, CaseIterable, Identifiable {
  case takeProfit = "take-profit"
  case stopLoss = "stop-loss"
  var id: String { rawValue }
  var title: String { self == .takeProfit ? "Take profit" : "Stop loss" }
  var defaultPercent: Int { self == .takeProfit ? 10 : -10 }
}

struct ExitLegDraft {
  var target = LimitOrderDraft()
  var quantityText = ""

  mutating func setEnabled(_ enabled: Bool, kind: ExitLegKind, reference: Double?) {
    let needsPrice = target.price == nil
    target.setEnabled(enabled, reference: reference, side: .sell)
    if enabled && needsPrice { target.preset(kind.defaultPercent, reference: reference) }
  }

  func request(kind: ExitLegKind, asset: Asset, slippage: SlippagePreset) -> ExecutionQuoteRequest {
    ExecutionQuoteRequest(
      provider: nil, side: "sell",
      input: .init(chain: asset.chainID, address: asset.id),
      output: .init(chain: asset.chainID, address: asset.settlement?.address ?? ""),
      amount: quantityText.trimmingCharacters(in: .whitespacesAndNewlines),
      orderType: kind == .takeProfit ? .limit : .stopLoss,
      slippageBps: slippage.basisPoints,
      limitPriceUsd: kind == .takeProfit && target.price != nil ? target.priceText : nil,
      triggerPriceUsd: kind == .stopLoss && target.price != nil ? target.priceText : nil,
      context: .init(sender: nil, recipient: nil))
  }

  func validation(kind: ExitLegKind, reference: Double?) -> String? {
    guard target.isEnabled else { return nil }
    guard let price = target.price else { return "Enter a positive target price." }
    guard let reference, reference.isFinite, reference > 0 else {
      return "Waiting for a current market price."
    }
    if kind == .takeProfit && price <= reference {
      return "Take profit must be above the current price."
    }
    if kind == .stopLoss && price >= reference {
      return "Stop loss must be below the current price."
    }
    return nil
  }
}

/// The two exit legs keep separate quantities and chart lines.
struct ExitOrderDraft {
  private(set) var isEnabled = false
  private var initialized = false
  var takeProfit = ExitLegDraft()
  var stopLoss = ExitLegDraft()

  mutating func setEnabled(_ enabled: Bool, reference: Double?) {
    isEnabled = enabled
    takeProfit.target.invalidateChartEvents()
    stopLoss.target.invalidateChartEvents()
    if enabled && !initialized {
      takeProfit.setEnabled(true, kind: .takeProfit, reference: reference)
      stopLoss.setEnabled(true, kind: .stopLoss, reference: reference)
      initialized = true
    }
  }

  func chartLines(asset: Asset) -> [ChartLimitLine] {
    guard isEnabled else { return [] }
    return ExitLegKind.allCases.compactMap { kind in
      let leg = kind == .takeProfit ? takeProfit : stopLoss
      guard leg.target.isEnabled else { return nil }
      var line = leg.target.chartLine(asset: asset, side: .sell)
      line.id = kind.rawValue
      return line
    }
  }

  mutating func receiveChartPrice(id: String, value: Double?, revision: String) {
    guard isEnabled else { return }
    switch ExitLegKind(rawValue: id) {
    case .takeProfit: takeProfit.target.receiveChartPrice(value, revision: revision)
    case .stopLoss: stopLoss.target.receiveChartPrice(value, revision: revision)
    case nil: break
    }
  }
}
