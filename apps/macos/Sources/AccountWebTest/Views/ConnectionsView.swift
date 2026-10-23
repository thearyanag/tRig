import SwiftUI

struct SessionView: View {
  @ObservedObject var session: BrowserSession
  @ObservedObject var chatAccount: ChatGPTAccount
  @Binding var showAssistant: Bool
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button {
          session.webView.goBack()
        } label: {
          Image(systemName: "chevron.left")
        }.help("Back")
        Button("Home") { session.webView.load(URLRequest(url: session.service.url)) }
        Button("Reload") { session.webView.reload() }
        Text(session.host.isEmpty ? session.service.url.host! : session.host).font(
          .system(.body, design: .monospaced))
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
        Divider()
        ResearchSidebar(session: session, chatAccount: chatAccount, showAssistant: $showAssistant)
      }
      Divider()
      Text(session.cookieSummary).font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }.onAppear { session.start() }
  }
}
