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
      guard session.profile?.wallet == wallet else {
        throw PortfolioReadFailure(message: "The Fomo account changed. Refresh to confirm it.")
      }
      if let failure = result as? [String: Any] {
        throw fomoFailure(failure)
      }
      guard let string = result as? String, let data = string.data(using: .utf8) else {
        throw PortfolioReadFailure(message: "Fomo returned an unreadable portfolio response.")
      }
      return PortfolioProviderPayload(
        source: .fomo, wallet: wallet, period: period, data: data, fetchedAt: Date())
    } catch {
      try Task.checkCancellation()
      if error is CancellationError { throw error }
      if let failure = error as? PortfolioReadFailure { throw failure }
      throw PortfolioReadFailure(
        message: "Fomo's portfolio reader was interrupted. Try refreshing again.")
    }
  }

  private func fomoFailure(_ failure: [String: Any]) -> PortfolioReadFailure {
    let message: String
    switch failure["state"] as? String {
    case "anonymous":
      message = "Fomo is signed out. Reconnect it in Settings to refresh."
    case "loading":
      message = "Fomo is still restoring its session. Try refreshing shortly."
    case "accountChanged":
      message = "The Fomo account changed. Refresh to confirm it."
    case "readerChanged":
      message = "Fomo changed its portfolio reader. Update tRig and try again."
    case "invalidResponse":
      message = "Fomo returned an unreadable balance response."
    case "timeout":
      message = "Fomo's balance request timed out. Try refreshing again."
    case "apiError":
      switch failure["status"] as? Int {
      case 401: message = "Fomo rejected the session (HTTP 401). Reconnect it in Settings."
      case 403: message = "Fomo denied the balance request (HTTP 403)."
      case 429: message = "Fomo is rate limiting balance requests (HTTP 429). Try again shortly."
      case let status? where (400...599).contains(status):
        message = "Fomo's balance request failed (HTTP \(status))."
      default: message = "Fomo's balance request failed."
      }
    case "unavailable":
      message = "Fomo's account details are unavailable. Check its connection in Settings."
    default:
      message = "Fomo's balance request did not return a usable response. Try refreshing again."
    }
    return PortfolioReadFailure(message: message)
  }
}
