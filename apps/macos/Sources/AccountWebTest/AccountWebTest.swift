import SwiftUI
import WebKit
import AppKit

@main
struct AccountWebTestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("tRig") {
            ContentView().frame(minWidth: 900, minHeight: 680)
        }.defaultSize(width: 1180, height: 820)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Service: String, CaseIterable, Identifiable {
    case pump = "Pump", fomo = "Fomo"
    var id: String { rawValue }
    var url: URL { URL(string: self == .pump ? "https://pump.fun/" : "https://fomo.family/")! }
    // Fixed identifiers deliberately preserve each service's own website data across launches.
    var storeID: UUID { UUID(uuidString: self == .pump
        ? "4B6C6332-C8A3-45BD-A499-3F14EB769301"
        : "D86281DA-0809-42F5-A828-C0F0CBA4C902")! }
}

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
    @Published var cookieSummary = "Session not checked. Cookie presence does not prove you are signed in."
    private var observations: [NSKeyValueObservation] = []
    private var popups: [PopupWindow] = []
    private var started = false
    @Published var pumpProfile: PumpProfile?
    @Published var profileLoading = false
    @Published var profileError: String?
    private var profileTask: Task<Void, Never>?
    private var profileReadID = UUID()

    func readPumpProfile() {
        guard service == .pump, webView.url?.scheme == "https", webView.url?.host == "pump.fun", !profileLoading else { return }
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
                let current = try PumpProfileRules.sessionCookie(in: await self.webView.configuration.websiteDataStore.httpCookieStore.allCookies())
                guard current.value == cookie.value else { throw PumpReadError.changedSession }
                guard self.profileReadID == readID else { return }
                self.pumpProfile = profile
            } catch is CancellationError {
                // Navigation or a newer read superseded this request.
            } catch {
                guard self.profileReadID == readID, !Task.isCancelled else { return }
                self.profileError = (error as? PumpReadError)?.errorDescription ?? "The native profile request could not complete. Check the connection and retry."
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
            }
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
            let summary = groups.keys.sorted().map { "\($0): \(groups[$0]!.count)" }.joined(separator: " · ")
            let count = cookies.count
            Task { @MainActor [weak self] in
                self?.cookieSummary = "\(count) cookies in this app’s \(self?.service.rawValue ?? "") store. \(summary.isEmpty ? "No cookies yet." : summary)\nCookie counts are diagnostic only. Verify login on the website, then quit and reopen this app."
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { failure = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
    private func report(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        // Localized network errors may contain OAuth URLs; show only domain and numeric code.
        failure = "Page could not load (\(e.domain), \(e.code)). Try Reload or return to the service home page."
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failure = "Web content stopped. Use Reload to try again."
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        if scheme == "https" || scheme == "about" {
            decisionHandler(.allow)
        } else {
            // Background frames may probe app links; only surface a warning for a user's navigation.
            if navigationAction.navigationType == .linkActivated {
                failure = "This test supports HTTPS web login. External-app links are not opened automatically."
            }
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
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
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        guard let window = webView.window else { completionHandler(); return }
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Website message"
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let window = webView.window else { completionHandler(false); return }
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Website confirmation"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in completionHandler(response == .alertFirstButtonReturn) }
    }
}

@MainActor
final class PopupWindow: NSWindowController, NSWindowDelegate {
    let webView: WKWebView
    var onClose: (() -> Void)?
    private var observation: NSKeyValueObservation?
    init(webView: WKWebView, service: Service) {
        self.webView = webView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 740),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(service.rawValue) — Login popup"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        observation = webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            Task { @MainActor [weak self] in
                self?.window?.title = "\(service.rawValue) — \(view.url?.host ?? "Login popup")"
            }
        }
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

struct WebSurface: NSViewRepresentable {
    let session: BrowserSession
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct SessionView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var chatAccount: ChatGPTAccount
    @Binding var showAssistant: Bool
    @State private var panel = "Profile"
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { session.webView.goBack() } label: { Image(systemName: "chevron.left") }.help("Back")
                Button("Home") { session.webView.load(URLRequest(url: session.service.url)) }
                Button("Reload") { session.webView.reload() }
                Text(session.host.isEmpty ? session.service.url.host! : session.host)
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Spacer()
                if session.loading { ProgressView().controlSize(.small) }
                Button("Check Session") { session.checkSession() }
            }.padding(10)
            if let failure = session.failure {
                Text(failure).font(.callout).foregroundStyle(.orange).padding(8)
            }
            Divider()
            HStack(spacing: 0) {
                WebSurface(session: session)
                if showAssistant {
                    Divider()
                    ChatGPTSidebar(account: chatAccount, conversation: session.chat, session: session) { text in
                        if session.service == .pump { session.callouts.text = text; panel = "Callouts" }
                        else { session.fomoNative.postText = text }
                        showAssistant = false
                    }
                } else if session.service == .pump {
                    Divider()
                    VStack(spacing: 0) {
                        Picker("Native panel", selection: $panel) {
                            Text("Profile").tag("Profile")
                            Text("Callouts").tag("Callouts")
                        }.pickerStyle(.segmented).padding(10)
                        if panel == "Profile" { PumpProfilePanel(session: session) }
                        else { PumpCalloutPanel(model: session.callouts) }
                    }.frame(width: 358)
                } else {
                    Divider()
                    FomoNativePanel(model: session.fomoNative)
                }
            }
            Divider()
            Text(session.cookieSummary).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }.onAppear { session.start() }
    }
}

struct ContentView: View {
    @StateObject private var pump = BrowserSession(service: .pump)
    @StateObject private var fomo = BrowserSession(service: .fomo)
    @State private var selected: Service = .pump
    @StateObject private var chatAccount = ChatGPTAccount()
    @State private var showAssistant = true
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("tRig — trading rig").font(.headline)
                    Text("Sign in on the website below. Each service keeps its own session on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(showAssistant ? "Native tools" : "Assistant") { showAssistant.toggle() }
                Picker("Service", selection: $selected) {
                    ForEach(Service.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 180)
            }.padding(14)
            Divider()
            SessionView(session: selected == .pump ? pump : fomo, chatAccount: chatAccount, showAssistant: $showAssistant)
                .id(selected)
        }.onChange(of: chatAccount.selectedID) { _, _ in
            pump.chat.clear(); fomo.chat.clear()
        }
    }
}
