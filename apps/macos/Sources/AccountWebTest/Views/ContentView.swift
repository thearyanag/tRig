import SwiftUI

struct ContentView: View {
  @StateObject private var pump = BrowserSession(service: .pump)
  @StateObject private var fomo = BrowserSession(service: .fomo)
  @State private var selected: Service = .pump
  @ObservedObject var chatAccount: ChatGPTAccount
  @State private var showAssistant = true
  @State private var workbench = true
  @State private var workspace = WorkspaceStore.shared
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("tRig — trading rig").font(.headline)
          Text("From discovery to an informed thesis.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Picker("Workspace mode", selection: $workbench) {
          Text("Workbench").tag(true)
          Text("Connections").tag(false)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
        Button(showAssistant ? "Native tools" : "Assistant") { showAssistant.toggle() }
        Picker("Service", selection: $selected) {
          ForEach(Service.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
      }.padding(14)
      Divider()
      if workbench {
        HStack(spacing: 0) {
          WorkspaceView()
          Divider()
          ResearchSidebar(
            session: selected == .pump ? pump : fomo, chatAccount: chatAccount,
            showAssistant: $showAssistant, asset: workspace.selectedAsset
          )
          .id(selected)
        }
      } else {
        SessionView(
          session: selected == .pump ? pump : fomo, chatAccount: chatAccount,
          showAssistant: $showAssistant
        )
        .id(selected)
      }
    }.onChange(of: chatAccount.selectedID) { _, _ in
      pump.chat.clear()
      fomo.chat.clear()
    }
  }
}
