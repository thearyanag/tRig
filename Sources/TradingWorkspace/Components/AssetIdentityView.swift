import AppKit
import SwiftUI

struct AssetIdentityView: View {
  let asset: Asset
  @State private var didCopy = false

  var body: some View {
    HStack(spacing: 12) {
      AssetIconView(asset: asset)
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 7) {
          Text(asset.name).font(AppTypography.font(size: 15, weight: .semibold)).lineLimit(1)
          Text(asset.symbol).font(AppTypography.callout).foregroundStyle(.secondary)
        }
        HStack(spacing: 7) {
          Text(asset.network)
          Text("|").foregroundStyle(.tertiary)
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(asset.id, forType: .string)
            didCopy = true
          } label: {
            HStack(spacing: 6) {
              Text(asset.shortAddress)
              Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            }
          }
          .buttonStyle(.plain)
          .help(didCopy ? "Contract address copied" : "Copy contract address")
          .accessibilityLabel("Copy \(asset.symbol) contract address")
          .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
          }
        }
        .font(AppTypography.caption).foregroundStyle(.secondary).fixedSize()
      }
    }
  }
}
