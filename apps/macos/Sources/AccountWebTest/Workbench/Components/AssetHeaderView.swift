import AppKit
import SwiftUI

struct AssetHeaderView: View {
  let asset: Asset
  var market: SampleMarket? = nil
  var livePrice: Double? = nil
  var isLiveMarket = false
  @Binding var isWatched: Bool
  @State private var didCopy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Image(systemName: asset.systemImage)
          .font(.title2)
          .foregroundStyle(.tint)
          .frame(width: 40, height: 40)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(asset.name).font(.headline)
            Text(asset.symbol).foregroundStyle(.secondary)
          }
          HStack(spacing: 8) {
            Text(asset.network)
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(asset.id, forType: .string)
              didCopy = true
            } label: {
              Label(asset.shortAddress, systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(didCopy ? "Contract address copied" : "Copy contract address")
            .accessibilityLabel("Copy \(asset.symbol) contract address")
            .task(id: didCopy) {
              guard didCopy else { return }
              try? await Task.sleep(for: .seconds(2))
              didCopy = false
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Button {
          isWatched.toggle()
        } label: {
          Image(systemName: isWatched ? "star.fill" : "star")
            .foregroundStyle(isWatched ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(isWatched ? "Remove from watchlist" : "Add to watchlist")
        .accessibilityLabel(
          isWatched ? "Remove \(asset.symbol) from watchlist" : "Add \(asset.symbol) to watchlist")
        Spacer()
        Text(isLiveMarket ? "GeckoTerminal" : "Sample data")
          .font(.caption).foregroundStyle(.secondary)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(.quaternary, in: Capsule())
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 32) {
          price
          if !isLiveMarket {
            metric("24h volume", value: market.map { DisplayFormat.compactCurrency($0.volume) })
            metric("Liquidity", value: market.map { DisplayFormat.compactCurrency($0.liquidity) })
          }
          Spacer(minLength: 0)
        }
        HStack {
          price
          Spacer(minLength: 0)
        }
      }
    }
  }

  private var price: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(
        isLiveMarket
          ? livePrice.map {
            DisplayFormat.currency(Decimal($0), decimals: DisplayFormat.priceDecimals($0))
          } ?? "—"
          : market.map { DisplayFormat.currency($0.price, decimals: 4) } ?? "—"
      )
      .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
      if isLiveMarket {
        Text("\(asset.symbol) / USD").font(.caption).foregroundStyle(.secondary)
      } else if let market {
        Text(
          "\(market.changePercent >= 0 ? "+" : "")\(DisplayFormat.number(market.changePercent, decimals: 2))%"
        )
        .font(.callout.weight(.medium))
        .foregroundStyle(market.changePercent >= 0 ? Color.green : Color.red)
        Text("24h").font(.caption).foregroundStyle(.secondary)
      } else {
        Text("Market data unavailable").font(.caption).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func metric(_ title: String, value: String?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value ?? "—").font(.callout.weight(.medium)).monospacedDigit()
    }
    .accessibilityElement(children: .combine)
  }
}

#Preview {
  AssetHeaderView(asset: .backpack, market: .backpack, isWatched: .constant(true))
    .padding().frame(width: 700)
}
