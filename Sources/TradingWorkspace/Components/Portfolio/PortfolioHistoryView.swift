import Charts
import SwiftUI

struct PortfolioHistoryView: View {
  let snapshot: PortfolioSnapshot?
  @Binding var period: PortfolioPeriod
  let loading: Bool
  let currentPeriod: Bool
  @State private var hovered: Int64?

  private var points: [PortfolioHistoryPoint] {
    guard currentPeriod else { return [] }
    return (snapshot?.history ?? []).filter { Double($0.valueUsd).map { $0.isFinite } == true }
  }
  private var segmentCounts: [Int: Int] {
    Dictionary(grouping: points, by: \.segment).mapValues(\.count)
  }
  private var domain: ClosedRange<Double> {
    let values = points.compactMap { Double($0.valueUsd) }
    let low = values.min() ?? 0
    let high = values.max() ?? 1
    let padding = max((high - low) * 0.12, max(abs(high) * 0.005, 0.01))
    return max(0, low - padding)...max(0.02, high + padding)
  }
  private var selected: PortfolioHistoryPoint? { points.first { $0.time == hovered } }

  var body: some View {
    let counts = segmentCounts
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Text("Portfolio value").font(AppTypography.font(size: 16, weight: .semibold))
        Spacer()
        HStack(spacing: 2) {
          ForEach(PortfolioPeriod.allCases) { value in
            Button {
              period = value
            } label: {
              Text(value.name).font(AppTypography.font(size: 14, weight: .medium)).frame(
                width: 48, height: 27)
            }
            .buttonStyle(
              TerminalControlStyle(
                fill: period == value ? TerminalStyle.accent : .clear,
                border: period == value ? TerminalStyle.accent : TerminalStyle.border)
            )
            .accessibilityLabel("Show \(value.name) portfolio history")
            .accessibilityAddTraits(period == value ? .isSelected : [])
          }
        }
        Text(Date().formatted(.dateTime.day().month(.abbreviated).year()))
          .font(AppTypography.font(size: 12)).foregroundStyle(.secondary)
      }
      Group {
        if points.isEmpty {
          VStack(spacing: 10) {
            if loading {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "chart.xyaxis.line").font(.title2).foregroundStyle(.secondary)
            }
            Text(
              loading
                ? "Loading portfolio history…"
                : snapshot?.historyMessage ?? "Portfolio history is not available yet."
            )
            .font(AppTypography.font(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(
              .center)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          Chart {
            ForEach(points) { point in
              let value = Double(point.valueUsd) ?? 0
              AreaMark(
                x: .value("Time", point.date), yStart: .value("Base", domain.lowerBound),
                yEnd: .value("Value", value), series: .value("Segment", point.segment)
              )
              .foregroundStyle(
                LinearGradient(
                  colors: [TerminalStyle.accent.opacity(0.18), TerminalStyle.accent.opacity(0.02)],
                  startPoint: .top, endPoint: .bottom))
              LineMark(
                x: .value("Time", point.date), y: .value("Value", value),
                series: .value("Segment", point.segment)
              )
              .foregroundStyle(TerminalStyle.accent).lineStyle(StrokeStyle(lineWidth: 1.8))
              if counts[point.segment] == 1 {
                PointMark(x: .value("Time", point.date), y: .value("Value", value))
                  .foregroundStyle(TerminalStyle.accent).symbolSize(22)
              }
            }
            if let selected {
              RuleMark(x: .value("Selected", selected.date)).foregroundStyle(
                .secondary.opacity(0.5)
              )
              .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
              PointMark(
                x: .value("Time", selected.date), y: .value("Value", Double(selected.valueUsd) ?? 0)
              )
              .foregroundStyle(TerminalStyle.accent).symbolSize(32)
              .annotation(position: .top, spacing: 8) {
                VStack(spacing: 4) {
                  Text(selected.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(AppTypography.font(size: 12)).foregroundStyle(.secondary)
                  Text(PortfolioFormat.currency(selected.valueUsd)).font(
                    AppTypography.font(size: 14, weight: .medium)
                  ).monospacedDigit()
                }
                .padding(8).background(TerminalStyle.panel, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(TerminalStyle.border))
              }
            }
          }
          .chartLegend(.hidden).chartYScale(domain: domain)
          .chartXScale(range: .plotDimension(padding: 20))
          .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
              AxisGridLine().foregroundStyle(.white.opacity(0.08))
              AxisValueLabel {
                if let n = value.as(Double.self) {
                  Text(DisplayFormat.compactCurrency(Decimal(n))).font(AppTypography.font(size: 12))
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
          .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { value in
              AxisGridLine().foregroundStyle(.white.opacity(0.05))
              AxisValueLabel {
                if let date = value.as(Date.self) {
                  Text(
                    date.formatted(
                      period == .day
                        ? .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(
                          Locale(identifier: "en_GB"))
                        : .dateTime.month(.abbreviated).day())
                  )
                  .font(AppTypography.font(size: 12)).foregroundStyle(.secondary)
                  .frame(width: 60, height: 18).fixedSize()
                }
              }
            }
          }
          .chartOverlay { proxy in
            GeometryReader { geometry in
              Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                  switch phase {
                  case .active(let location):
                    guard let anchor = proxy.plotFrame else { return }
                    let frame = geometry[anchor]
                    guard frame.contains(location),
                      let date = proxy.value(atX: location.x - frame.minX, as: Date.self)
                    else {
                      hovered = nil
                      return
                    }
                    hovered =
                      points.min {
                        abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                      }?.time
                  case .ended: hovered = nil
                  }
                }
            }
          }
          .accessibilityLabel("Portfolio value history in US dollars")
        }
      }
      .frame(height: 164)
      if !points.isEmpty, let message = snapshot?.historyMessage {
        Text(message).font(AppTypography.font(size: 12)).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 14)
  }
}
