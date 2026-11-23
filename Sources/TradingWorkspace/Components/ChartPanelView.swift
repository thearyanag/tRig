import SwiftUI

struct ChartPanelView: View {
  var asset: Asset = .backpack
  var draftLines: [ChartLimitLine] = []
  var onDraftPriceChange: (String, Double?, String) -> Void = { _, _, _ in }
  var onPriceChange: (Double) -> Void = { _ in }
  @State private var backend = LocalDataService.shared
  @State private var status = ChartStatus()
  @State private var reloadID = UUID()
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    VStack(spacing: 0) {
      if let baseURL = backend.baseURL {
        TradingViewWebView(
          baseURL: baseURL, asset: asset, status: status, isActive: scenePhase != .background,
          reloadID: reloadID, draftLines: draftLines, onDraftPriceChange: onDraftPriceChange
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error = backend.error {
        PlaceholderPanel(
          title: "Chart unavailable", systemImage: "wifi.exclamationmark", message: error)
      } else {
        VStack(spacing: 12) {
          ProgressView()
          Text("Starting chart…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Divider()
      HStack(spacing: 8) {
        if status.phase == "loading", backend.error == nil { ProgressView().controlSize(.mini) }
        Text(
          backend.error
            ?? (["error", "empty"].contains(status.phase)
              ? status.message : "\(asset.symbol)")
        )
        .lineLimit(2)
        .foregroundStyle(
          status.phase == "error" || backend.error != nil ? Color.orange : Color.secondary)
        Spacer(minLength: 0)
        if let fetched = status.fetchedAt {
          Text("Updated \(fetched.formatted(date: .omitted, time: .standard))")
            .foregroundStyle(.secondary)
        }
        Button {
          if backend.error != nil { backend.restart() } else { reloadID = UUID() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless).help("Reload chart")
      }
      .font(AppTypography.caption).padding(.horizontal, 10).padding(.vertical, 4)
      .background(TerminalStyle.canvas)
    }
    .task { backend.start() }
    .onChange(of: status.lastClose) { _, price in if let price { onPriceChange(price) } }
  }
}
