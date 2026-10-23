import SwiftUI

struct ResearchSidebar: View {
  @ObservedObject var session: BrowserSession
  @ObservedObject var chatAccount: ChatGPTAccount
  @Binding var showAssistant: Bool
  var asset: Asset? = nil
  @ObservedObject private var pumpTools: PumpCalloutModel
  @ObservedObject private var fomoTools: FomoNativeModel
  @State private var panel = "Profile"
  init(
    session: BrowserSession, chatAccount: ChatGPTAccount, showAssistant: Binding<Bool>,
    asset: Asset? = nil
  ) {
    self.session = session
    self.chatAccount = chatAccount
    self._showAssistant = showAssistant
    self.asset = asset
    self.pumpTools = session.callouts
    self.fomoTools = session.fomoNative
  }
  var body: some View {
    VStack(spacing: 0) {
      if let asset {
        VStack(alignment: .leading, spacing: 6) {
          Text("\(asset.symbol) · Solana").font(.headline)
          Text(asset.shortAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
          Button("Read \(session.service.rawValue) discussions") {
            showAssistant = false
            if session.service == .pump {
              panel = "Callouts"
              session.callouts.readInput = asset.id
              session.callouts.read()
            } else {
              session.fomoNative.tokenInput = asset.id
              session.fomoNative.readFeed()
            }
          }.disabled(pumpTools.busy || fomoTools.busy)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        Divider()
      }
      if showAssistant {
        ChatGPTSidebar(
          account: chatAccount, conversation: session.chat, session: session,
          assetContext: asset.map { ResearchContext.asset($0) }
        ) { text in
          if session.service == .pump {
            session.callouts.text = text
            panel = "Callouts"
          } else {
            session.fomoNative.postText = text
          }
          showAssistant = false
        }
      } else if session.service == .pump {
        Picker("Native panel", selection: $panel) {
          Text("Profile").tag("Profile")
          Text("Callouts").tag("Callouts")
        }.pickerStyle(.segmented).padding(10)
        if panel == "Profile" {
          PumpProfilePanel(session: session)
        } else {
          PumpCalloutPanel(model: session.callouts)
        }
      } else {
        FomoNativePanel(model: session.fomoNative)
      }
    }.frame(width: 368)
  }
}
