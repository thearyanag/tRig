import AppKit
import WebKit

@MainActor
final class ConnectionPopupWindow: NSWindowController, NSWindowDelegate {
  let webView: WKWebView
  var onClose: (() -> Void)?
  private var observation: NSKeyValueObservation?
  init(webView: WKWebView, service: ConnectionService) {
    self.webView = webView
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 650, height: 740),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = "\(service.name) — Login popup"
    window.contentView = webView
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.delegate = self
    observation = webView.observe(\.url, options: [.new]) { [weak self] view, _ in
      Task { @MainActor [weak self] in
        self?.window?.title = "\(service.name) — \(view.url?.host ?? "Login popup")"
      }
    }
  }
  required init?(coder: NSCoder) { nil }
  func windowWillClose(_ notification: Notification) { onClose?() }
}
