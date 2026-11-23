import Foundation

/// Window-owned draft shared by the ticket and chart. No order is persisted or submitted.
struct LimitOrderDraft {
  private(set) var isEnabled = false
  private(set) var priceText = ""
  private(set) var revision = UUID().uuidString

  var price: Double? {
    guard QuoteAmount.isPositive(priceText), let value = Double(priceText),
      value.isFinite, value > 0
    else { return nil }
    return value
  }

  mutating func setEnabled(_ enabled: Bool, reference: Double?, side: TradeSide) {
    isEnabled = enabled
    revision = UUID().uuidString
    if enabled && price == nil { preset(side == .buy ? -5 : 5, reference: reference) }
  }

  mutating func setPrice(_ text: String) {
    guard text != priceText else { return }
    priceText = text
    revision = UUID().uuidString
  }

  mutating func invalidateChartEvents() { revision = UUID().uuidString }

  mutating func preset(_ percent: Int, reference: Double?) {
    guard let reference, reference.isFinite, reference > 0 else { return }
    setPrice(Self.formatted(reference * (1 + Double(percent) / 100)))
  }

  mutating func receiveChartPrice(_ value: Double?, revision: String) {
    guard isEnabled, revision == self.revision else { return }
    if let value {
      guard value.isFinite, value > 0 else { return }
      // Chart movement stays within the current native edit revision. Echoing a
      // new revision for every pointer move would turn drag acknowledgements
      // into commands that reposition the drawing underneath the gesture.
      priceText = Self.formatted(value)
    } else {
      setPrice("")
    }
  }

  func chartLine(asset: Asset, side: TradeSide) -> ChartLimitLine {
    ChartLimitLine(
      mint: asset.id, revision: revision, side: side.rawValue.lowercased(),
      price: isEnabled ? price : nil)
  }

  func request(asset: Asset, trade: TradeDraft) -> ExecutionQuoteRequest {
    ExecutionQuoteRequest(
      provider: nil, side: trade.side.rawValue.lowercased(),
      input: .init(
        chain: asset.chainID,
        address: trade.side == .buy ? asset.settlement?.address ?? "" : asset.id),
      output: .init(
        chain: asset.chainID,
        address: trade.side == .buy ? asset.id : asset.settlement?.address ?? ""),
      amount: trade.quoteAmount, orderType: .limit, slippageBps: trade.slippage.basisPoints,
      limitPriceUsd: price == nil ? nil : priceText,
      context: .init(sender: nil, recipient: nil))
  }

  static func formatted(_ value: Double) -> String {
    guard value.isFinite, value > 0 else { return "" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.maximumFractionDigits = DisplayFormat.priceDecimals(value)
    return formatter.string(from: NSNumber(value: value)) ?? ""
  }
}

struct ChartLimitLine: Codable, Equatable {
  var id = "limit"
  let mint: String
  let revision: String
  let side: String
  let price: Double?
}
