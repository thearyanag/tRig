import AppKit
import Observation
import WebKit

@MainActor @Observable
final class ConnectionBrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate,
  WKHTTPCookieStoreObserver
{
  let service: ConnectionService
  @ObservationIgnored var onDisconnect: (@MainActor () async throws -> Void)?
  let webView: WKWebView
  private(set) var profile: ConnectedProfile?
  private(set) var isReading = false
  private(set) var isPageLoading = false
  private(set) var error: String?
  private(set) var host = ""
  @ObservationIgnored private var started = false
  @ObservationIgnored private var browserVisible = false
  @ObservationIgnored private var readTask: Task<Void, Never>?
  @ObservationIgnored private var readID = UUID()
  @ObservationIgnored private var popups: [ConnectionPopupWindow] = []

  init(service: ConnectionService) {
    self.service = service
    let config = WKWebViewConfiguration()
    config.userContentController.addUserScript(
      WKUserScript(
        source: "performance.setResourceTimingBufferSize(2000);",
        injectionTime: .atDocumentStart, forMainFrameOnly: true))
    config.websiteDataStore = WKWebsiteDataStore(forIdentifier: service.storeID)
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    webView = WKWebView(frame: .zero, configuration: config)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    config.websiteDataStore.httpCookieStore.add(self)
  }

  func beginConnection() {
    browserVisible = true
    error = nil
    start()
    refresh()
  }
  func endConnection() {
    browserVisible = false
    readTask?.cancel()
    readID = UUID()
    isReading = false
    let windows = popups
    popups.removeAll()
    for popup in windows { popup.close() }
  }
  func restore() async {
    let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
    guard !cookies.isEmpty else { return }
    if service == .pump {
      refresh()
      await readTask?.value
      return
    }
    start()
    // The page's account state can become ready after its navigation finishes.
    // Recheck briefly while Settings is open, then stop background work.
    for _ in 0..<10 {
      guard !Task.isCancelled else { return }
      refresh()
      await readTask?.value
      if profile != nil { return }
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
    }
  }
  private func start() {
    guard !started else { return }
    started = true
    webView.load(URLRequest(url: service.homeURL))
  }
  func reload() {
    error = nil
    if started { webView.reload() } else { start() }
  }

  func refresh() {
    guard !isReading else { return }
    readTask?.cancel()
    let id = UUID()
    readID = id
    isReading = true
    error = nil
    readTask = Task { [weak self] in
      guard let self else { return }
      defer { if self.readID == id { self.isReading = false } }
      do {
        let result: ConnectedProfile?
        if self.service == .pump {
          let store = self.webView.configuration.websiteDataStore.httpCookieStore
          let cookies = await store.allCookies()
          guard let cookie = try? ConnectionProfileRules.pumpCookie(in: cookies) else {
            if self.readID == id { self.profile = nil }
            return
          }
          result = try await PumpConnectionClient().load(cookie: cookie)
          let current = try ConnectionProfileRules.pumpCookie(in: await store.allCookies())
          guard current.value == cookie.value else {
            throw ConnectionFailure(message: "The Pumpfun account changed. Refresh to confirm it.")
          }
        } else {
          guard self.webView.url?.scheme == "https", self.webView.url?.host == "fomo.family",
            !self.isPageLoading
          else { return }
          let value = try await self.webView.callAsyncJavaScript(
            FomoProfileBridge.read, arguments: [:], in: nil, contentWorld: .page)
          result = try ConnectionProfileRules.fomoProfile(value as Any)
        }
        try Task.checkCancellation()
        guard self.readID == id else { return }
        self.profile = result
      } catch {
        guard !Task.isCancelled, self.readID == id else { return }
        self.profile = nil
        self.error =
          (error as? ConnectionFailure)?.message
          ?? "\(self.service.name) could not read the profile. Reload the website and try again."
      }
    }
  }

  func disconnect() async {
    let previous = profile
    endConnection()
    profile = nil
    do { try await onDisconnect?() } catch {
      profile = previous
      self.error = "Saved portfolio data could not be cleared. Try disconnecting again."
      return
    }
    error = nil
    webView.stopLoading()
    let store = webView.configuration.websiteDataStore
    await store.removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    webView.loadHTMLString("", baseURL: nil)
    started = false
  }

  nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
    Task { @MainActor [weak self] in
      guard let self, self.browserVisible || self.profile != nil else { return }
      self.refresh()
    }
  }
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    guard webView === self.webView else { return }
    readTask?.cancel()
    readID = UUID()
    isReading = false
    profile = nil
    isPageLoading = true
    error = nil
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard webView === self.webView else { return }
    isPageLoading = false
    host = webView.url?.host ?? ""
    if webView.url?.scheme == "https" { refresh() }
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) { report(error, from: webView) }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    report(error, from: webView)
  }
  private func report(_ error: Error, from view: WKWebView) {
    guard view === webView else { return }
    let failure = error as NSError
    guard failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled else { return }
    isPageLoading = false
    self.error = "The sign-in page could not load. Reload to try again."
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard webView === self.webView else { return }
    isPageLoading = false
    error = "The sign-in page stopped. Reload to continue."
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let scheme = navigationAction.request.url?.scheme?.lowercased()
    decisionHandler(scheme == "https" || scheme == "about" ? .allow : .cancel)
  }
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    guard navigationAction.targetFrame == nil else { return nil }
    let child = WKWebView(frame: .zero, configuration: configuration)
    child.navigationDelegate = self
    child.uiDelegate = self
    let popup = ConnectionPopupWindow(webView: child, service: service)
    popup.onClose = { [weak self, weak popup] in
      self?.popups.removeAll { $0 === popup }
      if self?.browserVisible == true { self?.refresh() }
    }
    popups.append(popup)
    popup.showWindow(nil)
    popup.window?.makeKeyAndOrderFront(nil)
    return child
  }
  func webViewDidClose(_ webView: WKWebView) { popups.first { $0.webView === webView }?.close() }
  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo
  ) async {
    guard let window = webView.window else { return }
    let alert = NSAlert()
    alert.messageText = frame.request.url?.host ?? service.name
    alert.informativeText = message
    _ = await alert.beginSheetModal(for: window)
  }
  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo
  ) async -> Bool {
    guard let window = webView.window else { return false }
    let alert = NSAlert()
    alert.messageText = frame.request.url?.host ?? service.name
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
  }
}
