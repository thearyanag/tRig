import SwiftUI
import WebKit

struct ConnectionBrowserView: View {
  let session: ConnectionBrowserSession
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text("Connect \(session.service.name)").font(AppTypography.bodySemibold)
        Label(
          session.host.isEmpty ? session.service.homeURL.host! : session.host, systemImage: "lock"
        )
        .font(AppTypography.caption).foregroundStyle(.secondary)
        Spacer()
        if session.isPageLoading || session.isReading { ProgressView().controlSize(.small) }
        Button {
          session.reload()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless).help("Reload sign-in page")
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      .padding(14)
      Divider()
      ConnectionWebSurface(session: session).frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      HStack(spacing: 16) {
        Text(
          session.error
            ?? "Complete sign-in on \(session.service.name). This window closes when your profile is confirmed."
        )
        .font(AppTypography.callout).foregroundStyle(
          session.error == nil ? Color.secondary : .orange
        )
        .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button(session.isReading ? "Checking…" : "Check connection") { session.refresh() }
          .disabled(session.isReading || session.isPageLoading)
      }
      .padding(14)
    }
    .frame(width: 1000, height: 740)
    .font(AppTypography.body).preferredColorScheme(.dark)
    .task {
      session.beginConnection()
      while !Task.isCancelled {
        session.refresh()
        do { try await Task.sleep(for: .seconds(5)) } catch { break }
      }
    }
    .onChange(of: session.profile) { _, profile in if profile != nil { dismiss() } }
    .onDisappear { session.endConnection() }
  }
}

private struct ConnectionWebSurface: NSViewRepresentable {
  let session: ConnectionBrowserSession
  func makeNSView(context: Context) -> WKWebView { session.webView }
  func updateNSView(_ view: WKWebView, context: Context) {}
}
