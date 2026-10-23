import SwiftUI
import WebKit

struct WebSurface: NSViewRepresentable {
  let session: BrowserSession
  func makeNSView(context: Context) -> WKWebView { session.webView }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
