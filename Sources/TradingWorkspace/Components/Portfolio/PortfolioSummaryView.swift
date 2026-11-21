import SwiftUI

struct PortfolioSummaryView: View {
  let snapshot: PortfolioSnapshot?
  let period: PortfolioPeriod
  let isCurrentPeriod: Bool

  var body: some View {
    HStack(spacing: 20) {
      metric(
        "Portfolio value", snapshot?.totalValueUsd, percentage: nil, prominent: true,
        help: snapshot?.partial == true
          ? "Reported value has partial coverage. Open the data-quality notice for details."
          : "Current portfolio value reported by the selected accounts.")
      Divider().frame(height: 38)
      metric(
        "\(period.name == "All" ? "All available" : period.name) P&L",
        isCurrentPeriod ? snapshot?.periodPnlUsd : nil,
        percentage: isCurrentPeriod ? snapshot?.periodPnlPercent : nil, prominent: false,
        help:
          "Reported P&L for the selected period. Platforms can use different valuation methods and reporting boundaries; combined percentages are omitted when a common basis is unavailable."
      )
      Divider().frame(height: 38)
      metric(
        "Unrealized P&L", snapshot?.unrealizedPnlUsd, percentage: snapshot?.unrealizedPnlPercent,
        prominent: false,
        help:
          "Unrealized P&L on current tracked holdings. A dash means the available cost basis is insufficient."
      )
    }
    .padding(.horizontal, 24).frame(height: 88)
  }
  private func metric(
    _ title: String, _ value: String?, percentage: String?, prominent: Bool, help: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(AppTypography.font(size: 14)).foregroundStyle(.secondary)
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          amount(value, prominent: prominent)
          if let text = PortfolioFormat.percent(percentage) {
            Text("(\(text))").font(AppTypography.font(size: 14, weight: .medium)).foregroundStyle(
              color(value))
          }
        }
        amount(value, prominent: prominent)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading).help(help)
    .accessibilityElement(children: .combine)
  }
  private func amount(_ value: String?, prominent: Bool) -> some View {
    Text(PortfolioFormat.currency(value, signed: !prominent))
      .font(AppTypography.font(size: prominent ? 28 : 22, weight: .semibold))
      .foregroundStyle(prominent ? .primary : color(value)).monospacedDigit()
      .lineLimit(1).minimumScaleFactor(0.65)
  }
  private func color(_ value: String?) -> Color {
    guard let n = PortfolioFormat.decimal(value), n != 0 else { return .primary }
    return n > 0 ? TerminalStyle.buy : TerminalStyle.sell
  }
}
