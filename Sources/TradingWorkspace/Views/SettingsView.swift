import SwiftUI

struct SettingsView: View {
  @Environment(ConnectionStore.self) private var connections
  @Environment(TelegramSession.self) private var telegram
  @State private var connecting: ConnectionService?
  @State private var showTelegram = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Connections").font(AppTypography.font(size: 20, weight: .semibold))
        Text("Connect your accounts to view your username and wallet.")
          .font(AppTypography.callout).foregroundStyle(.secondary)
      }
      ForEach(ConnectionService.allCases) { service in
        ConnectionSettingsRow(session: connections.session(for: service)) { connecting = service }
      }
      TelegramSettingsRow(session: telegram) {
        showTelegram = true
        telegram.connect()
      }
      Text("Account connections are separate from trading wallets.")
        .font(AppTypography.caption).foregroundStyle(.secondary)
    }
    .padding(24).frame(width: 560)
    .font(AppTypography.body).preferredColorScheme(.dark)
    .task { await connections.restore() }
    .sheet(item: $connecting) { service in
      ConnectionBrowserView(session: connections.session(for: service))
    }
    .sheet(isPresented: $showTelegram, onDismiss: {
      if !telegram.isConnected { Task { await telegram.close() } }
    }) {
      TelegramConnectionView(session: telegram)
    }
  }
}

private struct ConnectionSettingsRow: View {
  let session: ConnectionBrowserSession
  let connect: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
        Text(session.service.name).font(AppTypography.bodySemibold)
        Spacer()
        if session.isReading {
          ProgressView().controlSize(.small)
        } else if session.profile != nil {
          Label("Connected", systemImage: "checkmark.circle.fill")
            .font(AppTypography.caption).foregroundStyle(.green)
        }
        if session.profile == nil {
          Button("Connect \(session.service.name)", action: connect)
            .buttonStyle(.bordered).disabled(session.isReading)
        }
      }
      if let profile = session.profile {
        LabeledContent("Username") {
          Text(profile.username.map { "@\($0)" } ?? "Not set").textSelection(.enabled)
        }
        LabeledContent("Wallet") {
          Text(profile.wallet).font(AppTypography.caption).monospaced()
            .textSelection(.enabled).lineLimit(2).multilineTextAlignment(.trailing)
        }
        .font(AppTypography.callout)
        HStack {
          Text("Checked \(profile.checkedAt.formatted(date: .omitted, time: .shortened))")
            .font(AppTypography.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Refresh") { session.refresh() }.disabled(session.isReading)
          Button("Disconnect") { Task { await session.disconnect() } }
            .disabled(session.isReading)
        }
        .controlSize(.small)
      }
      if let error = session.error {
        Text(error).font(AppTypography.callout).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(16)
    .background(TerminalStyle.panel, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TerminalStyle.border))
  }
}
