import AppKit
import SwiftUI
import WebKit

@MainActor
final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
  let service: Service
  let webView: WKWebView
  let callouts: PumpCalloutModel
  let fomoNative: FomoNativeModel
  let chat = ChatGPTConversation()
  @Published var host = ""
  @Published var loading = false
  @Published var failure: String?
  @Published var cookieSummary =
    "Session not checked. Cookie presence does not prove you are signed in."
  private var observations: [NSKeyValueObservation] = []
  private var popups: [PopupWindow] = []
  private var started = false
  @Published var pumpProfile: PumpProfile?
  @Published var profileLoading = false
  @Published var profileError: String?
  private var profileTask: Task<Void, Never>?
  private var profileReadID = UUID()

  func readPumpProfile() {
    guard service == .pump, webView.url?.scheme == "https", webView.url?.host == "pump.fun",
      !profileLoading
    else { return }
    profileTask?.cancel()
    let readID = UUID()
    profileReadID = readID
    pumpProfile = nil
    profileError = nil
    profileLoading = true
    profileTask = Task { [weak self] in
      guard let self else { return }
      defer { if self.profileReadID == readID { self.profileLoading = false } }
      do {
        let cookies = await self.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let cookie = try PumpProfileRules.sessionCookie(in: cookies)
        let profile = try await PumpProfileClient().load(cookie: cookie)
        try Task.checkCancellation()
        let current = try PumpProfileRules.sessionCookie(
          in: await self.webView.configuration.websiteDataStore.httpCookieStore.allCookies())
        guard current.value == cookie.value else { throw PumpReadError.changedSession }
        guard self.profileReadID == readID else { return }
        self.pumpProfile = profile
      } catch is CancellationError {
        // Navigation or a newer read superseded this request.
      } catch {
        guard self.profileReadID == readID, !Task.isCancelled else { return }
        self.profileError =
          (error as? PumpReadError)?.errorDescription
          ?? "The native profile request could not complete. Check the connection and retry."
      }
    }
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    guard webView === self.webView else { return }
    profileTask?.cancel()
    profileReadID = UUID()
    profileLoading = false
    pumpProfile = nil
    profileError = nil
  }

  init(service: Service) {
    self.service = service
    let config = WKWebViewConfiguration()
    config.websiteDataStore = WKWebsiteDataStore(forIdentifier: service.storeID)
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    webView = WKWebView(frame: .zero, configuration: config)
    callouts = PumpCalloutModel(store: config.websiteDataStore.httpCookieStore)
    fomoNative = FomoNativeModel(store: config.websiteDataStore.httpCookieStore)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    observations = [
      webView.observe(\.url, options: [.new]) { [weak self] view, _ in
        Task { @MainActor [weak self] in self?.host = view.url?.host ?? "" }
      },
      webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
        Task { @MainActor [weak self] in self?.loading = view.isLoading }
      },
    ]
  }
  func start() {
    guard !started else { return }
    started = true
    webView.load(URLRequest(url: service.url))
  }
  func checkSession() {
    // Values, names, authentication tokens and page content are never logged or exported.
    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
      let groups = Dictionary(grouping: cookies, by: \.domain)
      let summary = groups.keys.sorted().map { "\($0): \(groups[$0]!.count)" }.joined(
        separator: " · ")
      let count = cookies.count
      Task { @MainActor [weak self] in
        self?.cookieSummary =
          "\(count) cookies in this app’s \(self?.service.rawValue ?? "") store. \(summary.isEmpty ? "No cookies yet." : summary)\nCookie counts are diagnostic only. Verify login on the website, then quit and reopen this app."
      }
    }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { failure = nil }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    report(error)
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) { report(error) }
  private func report(_ error: Error) {
    let e = error as NSError
    if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
    // Localized network errors may contain OAuth URLs; show only domain and numeric code.
    failure =
      "Page could not load (\(e.domain), \(e.code)). Try Reload or return to the service home page."
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    failure = "Web content stopped. Use Reload to try again."
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let scheme = navigationAction.request.url?.scheme?.lowercased()
    if scheme == "https" || scheme == "about" {
      decisionHandler(.allow)
    } else {
      // Background frames may probe app links; only surface a warning for a user's navigation.
      if navigationAction.navigationType == .linkActivated {
        failure =
          "This test supports HTTPS web login. External-app links are not opened automatically."
      }
      decisionHandler(.cancel)
    }
  }
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    guard navigationAction.targetFrame == nil else { return nil }
    // Use WebKit's supplied configuration to preserve opener and OAuth popup relationships.
    let child = WKWebView(frame: .zero, configuration: configuration)
    child.navigationDelegate = self
    child.uiDelegate = self
    let popup = PopupWindow(webView: child, service: service)
    popup.onClose = { [weak self, weak popup] in
      self?.popups.removeAll { $0 === popup }
    }
    popups.append(popup)
    popup.showWindow(nil)
    popup.window?.makeKeyAndOrderFront(nil)
    return child
  }
  func webViewDidClose(_ webView: WKWebView) {
    popups.first { $0.webView === webView }?.close()
  }
  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable () -> Void
  ) {
    guard let window = webView.window else {
      completionHandler()
      return
    }
    let alert = NSAlert()
    alert.messageText = frame.request.url?.host ?? "Website message"
    alert.informativeText = message
    alert.beginSheetModal(for: window) { _ in completionHandler() }
  }
  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    guard let window = webView.window else {
      completionHandler(false)
      return
    }
    let alert = NSAlert()
    alert.messageText = frame.request.url?.host ?? "Website confirmation"
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { response in
      completionHandler(response == .alertFirstButtonReturn)
    }
  }
}
