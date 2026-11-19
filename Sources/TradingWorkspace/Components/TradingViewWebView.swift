import SwiftUI
import WebKit

struct TradingViewWebView: NSViewRepresentable {
  let baseURL: URL
  let asset: Asset
  let status: ChartStatus
  let isActive: Bool
  let reloadID: UUID
  @Environment(\.colorScheme) private var colorScheme

  func makeCoordinator() -> Coordinator { Coordinator(status: status) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(context.coordinator, name: "chartStatus")
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.isInspectable = true
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    var url = URLComponents(
      url: baseURL.appendingPathComponent("index.html"), resolvingAgainstBaseURL: false)!
    url.queryItems = [
      URLQueryItem(name: "theme", value: colorScheme == .dark ? "dark" : "light"),
      URLQueryItem(name: "mint", value: asset.id), URLQueryItem(name: "pool", value: asset.pool),
      URLQueryItem(name: "symbol", value: asset.symbol),
      URLQueryItem(name: "name", value: asset.name),
      URLQueryItem(name: "price", value: asset.priceUsd.map { String($0) } ?? ""),
    ]
    let target = url.url!
    if context.coordinator.loadedURL != target || context.coordinator.reloadID != reloadID {
      context.coordinator.loadedURL = target
      context.coordinator.reloadID = reloadID
      context.coordinator.isActive = isActive
      status.phase = "loading"
      status.message = "Loading chart…"
      view.load(URLRequest(url: target))
    } else if context.coordinator.isActive != isActive {
      context.coordinator.isActive = isActive
      view.evaluateJavaScript("window.chartHost?.setActive(\(isActive ? "true" : "false"))")
    }
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    view.evaluateJavaScript("window.chartHost?.dispose()")
    view.stopLoading()
    view.configuration.userContentController.removeScriptMessageHandler(forName: "chartStatus")
    view.navigationDelegate = nil
  }

  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let status: ChartStatus
    var loadedURL: URL?
    var reloadID: UUID?
    var isActive = true
    init(status: ChartStatus) { self.status = status }

    func userContentController(
      _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      status.receive(message.body)
    }
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
      view.evaluateJavaScript("window.chartHost?.setActive(\(isActive ? "true" : "false"))")
    }
    func webView(
      _ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      status.phase = "error"
      status.message = "Chart could not load: \(error.localizedDescription)"
    }
    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      status.phase = "error"
      status.message = "Chart could not load: \(error.localizedDescription)"
    }
    func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
      status.phase = "error"
      status.message = "Chart rendering stopped. Reload to reconnect."
    }
  }
}
