import AppKit
import Charts
import PortfolioPulseSupport
import SwiftUI
import WidgetKit

@main
struct PortfolioPulseWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: PortfolioPulseSnapshot.kind, provider: PulseProvider()) { entry in
      PortfolioPulseView(entry: entry)
    }
    .configurationDisplayName("Portfolio Pulse")
    .description("See your combined Pumpfun and Fomo portfolio.")
    .supportedFamilies([.systemMedium])
    .contentMarginsDisabled()
  }
}

private struct PulseEntry: TimelineEntry {
  let date: Date
  let snapshot: PortfolioPulseSnapshot?
}

private struct PulseProvider: TimelineProvider {
  func placeholder(in context: Context) -> PulseEntry { Self.example }

  func getSnapshot(in context: Context, completion: @escaping (PulseEntry) -> Void) {
    completion(context.isPreview ? Self.example : current())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<PulseEntry>) -> Void) {
    let entry = current()
    let next = entry.date.addingTimeInterval(15 * 60)
    let midnight = Calendar.autoupdatingCurrent.dateInterval(of: .day, for: entry.date)?.end ?? next
    let entries = entry.snapshot == nil ? [entry] : [entry, PulseEntry(date: midnight, snapshot: entry.snapshot)]
    completion(Timeline(entries: entries, policy: .after(min(next, midnight))))
  }

  private func current() -> PulseEntry {
    PulseEntry(date: .now, snapshot: PortfolioPulseStorage.shared()?.read())
  }

  private static var example: PulseEntry {
    let now = Date()
    let values = [41_432.0, 41_507, 41_485, 41_740, 41_702, 41_938, 42_012,
                  41_871, 42_110, 42_204, 42_330, 42_276, 42_540, 42_680.32]
    let points = values.enumerated().map { index, value in
      PortfolioPulseSnapshot.Point(
        date: now.addingTimeInterval(Double(index - values.count + 1) * 600), value: value)
    }
    return PulseEntry(date: now, snapshot: PortfolioPulseSnapshot(
      sources: "Pumpfun + Fomo", balance: 42_680.32, move: 1_248.50, movePercent: 3.01,
      history: [points], contributor: .init(symbol: "SOL", amount: 914.20, icon: "solana"),
      updatedAt: now))
  }
}

private struct PortfolioPulseView: View {
  let entry: PulseEntry
  @Environment(\.widgetRenderingMode) private var rendering

  private var primary: Color { rendering == .fullColor ? .white : .primary }
  private var secondary: Color { primary.opacity(0.72) }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Portfolio Pulse").font(.system(size: 16, weight: .semibold))
        Spacer(minLength: 6)
        if let snapshot = entry.snapshot {
          Text("Updated \(snapshot.updatedAt, style: .time)")
            .font(.system(size: 10)).monospacedDigit().foregroundStyle(secondary)
        }
      }
      .padding(.bottom, 8)
      Rectangle().fill(primary.opacity(0.14)).frame(height: 0.5)
      if let snapshot = entry.snapshot {
        portfolio(snapshot)
      } else {
        VStack(alignment: .leading, spacing: 4) {
          Text("Your portfolio at a glance").font(.system(size: 15, weight: .medium))
          Text("Open tRig to connect Pumpfun or Fomo.")
            .font(.system(size: 11)).foregroundStyle(secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 15).padding(.vertical, 11)
    .foregroundStyle(primary)
    .containerBackground(for: .widget) { background }
    .widgetURL(PortfolioPulseSnapshot.portfolioURL)
  }

  private func portfolio(_ snapshot: PortfolioPulseSnapshot) -> some View {
    let isToday = Calendar.autoupdatingCurrent.isDate(snapshot.updatedAt, inSameDayAs: entry.date)
    let move = isToday ? snapshot.move : nil
    let tint = changeColor(move)
    return VStack(spacing: 8) {
      HStack(alignment: .center, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(snapshot.sources).font(.system(size: 12)).foregroundStyle(secondary)
          Text(snapshot.balance.formatted(.currency(code: "USD")))
            .font(.system(size: 27, weight: .semibold)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.65)
          Text(moveLabel(move, percent: isToday ? snapshot.movePercent : nil))
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.75).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if isToday && !snapshot.history.isEmpty {
          chart(snapshot.history, tint: tint)
            .frame(maxWidth: 118, maxHeight: 63)
        } else {
          Text("History unavailable")
            .font(.system(size: 10)).foregroundStyle(secondary)
            .frame(maxWidth: 94, alignment: .trailing)
        }
      }
      .frame(maxHeight: .infinity)
      .privacySensitive()
      Rectangle().fill(primary.opacity(0.28)).frame(height: 0.5)
      HStack(spacing: 7) {
        if let contributor = snapshot.contributor {
          if let icon = contributor.icon {
            let file = icon == "solana" ? "solana.jpg" : "\(icon).png"
            if let url = Bundle.main.url(forResource: file, withExtension: nil),
              let image = NSImage(contentsOf: url)
            {
              Image(nsImage: image).resizable().scaledToFit()
                .frame(width: 15, height: 15).clipShape(RoundedRectangle(cornerRadius: 3))
                .accessibilityHidden(true)
            }
          }
          Text(contributor.symbol).font(.system(size: 12, weight: .semibold)).lineLimit(1)
          Text("Top unrealized").font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1)
          Spacer(minLength: 4)
          Text(signedCurrency(contributor.amount)).font(.system(size: 12, weight: .medium))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            .foregroundStyle(changeColor(contributor.amount))
        } else {
          Text("Holding P&L unavailable").font(.system(size: 10)).foregroundStyle(secondary)
          Spacer()
        }
      }
      .frame(height: 17)
      .privacySensitive()
    }
    .padding(.top, 7)
  }

  private func chart(_ segments: [[PortfolioPulseSnapshot.Point]], tint: Color) -> some View {
    let values = segments.flatMap { $0 }.map(\.value)
    let low = values.min() ?? 0
    let high = values.max() ?? 0
    let padding = max((high - low) * 0.10, max(abs(high), 1) * 0.0005)
    return Chart {
      ForEach(segments.indices, id: \.self) { segment in
        ForEach(segments[segment], id: \.date) { point in
          AreaMark(
            x: .value("Time", point.date), yStart: .value("Base", low - padding),
            yEnd: .value("Balance", point.value), series: .value("Segment", segment))
          .foregroundStyle(LinearGradient(
            colors: [tint.opacity(0.33), tint.opacity(0.02)],
            startPoint: .top, endPoint: .bottom))
          LineMark(
            x: .value("Time", point.date), y: .value("Balance", point.value),
            series: .value("Segment", segment))
          .foregroundStyle(tint)
          .lineStyle(StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        }
      }
    }
    .chartYScale(domain: (low - padding)...(high + padding))
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .accessibilityHidden(true)
  }

  private func signedCurrency(_ amount: Decimal) -> String {
    (amount > 0 ? "+" : "") + amount.formatted(.currency(code: "USD"))
  }

  private func moveLabel(_ amount: Decimal?, percent: Decimal?) -> String {
    guard let amount else { return "Today · unavailable" }
    let percentText = percent.map { value in
      let formatted = value.formatted(.number.precision(.fractionLength(2)))
      return " (\(value > 0 ? "+" : "")\(formatted)%)"
    } ?? ""
    return "\(signedCurrency(amount))\(percentText) today"
  }

  private func changeColor(_ amount: Decimal?) -> Color {
    guard rendering == .fullColor, let amount, amount != 0 else { return secondary }
    return amount > 0 ? Color(red: 0.13, green: 0.91, blue: 0.52)
      : Color(red: 1, green: 0.34, blue: 0.46)
  }

  private var background: some View {
    ZStack {
      LinearGradient(
        colors: [Color(red: 0.17, green: 0.23, blue: 0.37), Color(red: 0.06, green: 0.09, blue: 0.16)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
      RadialGradient(
        colors: [Color(red: 0.30, green: 0.52, blue: 0.92).opacity(0.53), .clear],
        center: .init(x: 0.24, y: 0), startRadius: 0, endRadius: 154)
      LinearGradient(
        stops: [.init(color: .white.opacity(0.21), location: 0), .init(color: .clear, location: 0.22)],
        startPoint: .top, endPoint: .bottom)
      ContainerRelativeShape().strokeBorder(
        LinearGradient(
          colors: [.white.opacity(0.60), .white.opacity(0.08), .blue.opacity(0.32)],
          startPoint: .top, endPoint: .bottom),
        lineWidth: 1)
    }
  }
}
