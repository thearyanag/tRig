import Foundation
import WebKit

@MainActor
struct PortfolioReadClient {
  func read(source: ConnectionService, connections: ConnectionStore, period: PortfolioPeriod)
    async throws -> PortfolioProviderPayload
  {
    let session = connections.session(for: source)
    guard let wallet = session.profile?.wallet else {
      throw PortfolioReadFailure(
        message: "Connect \(source.name) in Settings to load its portfolio.")
    }
    if source == .pump {
      return try await PumpPortfolioClient(session: session).read(period: period)
    }
    guard session.webView.url?.host == "fomo.family", !session.isPageLoading else {
      throw PortfolioReadFailure(
        message: "Fomo is still restoring its session. Try refreshing shortly.")
    }
    do {
      let readID = UUID().uuidString
      let webView = session.webView
      let result = try await withTaskCancellationHandler {
        try await webView.callAsyncJavaScript(
          FomoPortfolioBridge.read,
          arguments: ["expectedWallet": wallet, "period": period.rawValue, "readID": readID],
          in: nil, contentWorld: .page)
      } onCancel: {
        Task { @MainActor in
          _ = try? await webView.evaluateJavaScript(
            "if (window.__trigPortfolioRead?.id === '\(readID)') window.__trigPortfolioRead.controller.abort();"
          )
        }
      }
      try Task.checkCancellation()
      guard session.profile?.wallet == wallet, let string = result as? String,
        let data = string.data(using: .utf8)
      else {
        throw PortfolioReadFailure(message: "The Fomo account changed. Refresh to confirm it.")
      }
      return PortfolioProviderPayload(
        source: .fomo, wallet: wallet, period: period, data: data, fetchedAt: Date())
    } catch is CancellationError { throw CancellationError() } catch {
      throw PortfolioReadFailure(
        message:
          "Fomo's portfolio could not refresh. Check its connection in Settings and try again.")
    }
  }
}
