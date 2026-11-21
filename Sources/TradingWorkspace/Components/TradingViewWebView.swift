import SwiftUI
import WebKit

struct TradingViewWebView: NSViewRepresentable {
  let baseURL: URL
  let asset: Asset
  let status: ChartStatus
  let isActive: Bool
  let reloadID: UUID
  var draftLines: [ChartLimitLine] = []
  var onDraftPriceChange: (String, Double?, String) -> Void = { _, _, _ in }
  @Environment(\.colorScheme) private var colorScheme

  func makeCoordinator() -> Coordinator { Coordinator(status: status) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(context.coordinator, name: "chartStatus")
    configuration.userContentController.add(context.coordinator, name: "limitDraft")
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.isInspectable = true
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    context.coordinator.onDraftPriceChange = onDraftPriceChange
    let lineChanged = context.coordinator.draftLines != draftLines
    context.coordinator.draftLines = draftLines
    var url = URLComponents(
      url: baseURL.appendingPathComponent("index.html"), resolvingAgainstBaseURL: false)!
    url.queryItems = [
      URLQueryItem(name: "theme", value: colorScheme == .dark ? "dark" : "light"),
      URLQueryItem(name: "mint", value: asset.id), URLQueryItem(name: "pool", value: asset.pool),
      URLQueryItem(name: "chain", value: asset.chainID),
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
    if lineChanged { context.coordinator.sendLimitLine(to: view) }
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    view.evaluateJavaScript("window.chartHost?.dispose()")
    view.stopLoading()
    view.configuration.userContentController.removeScriptMessageHandler(forName: "chartStatus")
    view.configuration.userContentController.removeScriptMessageHandler(forName: "limitDraft")
    view.navigationDelegate = nil
  }

  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let status: ChartStatus
    var loadedURL: URL?
    var reloadID: UUID?
    var isActive = true
    var draftLines: [ChartLimitLine] = []
    var onDraftPriceChange: (String, Double?, String) -> Void = { _, _, _ in }
    init(status: ChartStatus) { self.status = status }

    func userContentController(
      _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard message.frameInfo.isMainFrame else { return }
      if message.name == "limitDraft" {
        guard let value = message.body as? [String: Any], let id = value["id"] as? String,
          let line = draftLines.first(where: { $0.id == id }),
          line.price != nil, value["mint"] as? String == line.mint,
          value["revision"] as? String == line.revision
        else { return }
        if value["removed"] as? Bool == true {
          onDraftPriceChange(id, nil, line.revision)
        } else if let price = value["price"] as? Double, price.isFinite, price > 0 {
          onDraftPriceChange(id, price, line.revision)
        }
      } else {
        status.receive(message.body)
      }
    }
    func sendLimitLine(to view: WKWebView) {
      guard let data = try? JSONEncoder().encode(draftLines),
        let json = String(data: data, encoding: .utf8)
      else { return }
      view.evaluateJavaScript("window.chartHost?.setLimitDraft(\(json))")
    }
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
      view.evaluateJavaScript("window.chartHost?.setActive(\(isActive ? "true" : "false"))")
      sendLimitLine(to: view)
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
