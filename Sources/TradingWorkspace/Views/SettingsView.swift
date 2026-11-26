import SwiftUI

enum WorkspaceSettingsSection: String, CaseIterable, Identifiable {
  case connections, research

  var id: Self { self }
  var title: String { self == .connections ? "Connections" : "AI Providers" }
  var icon: String { self == .connections ? "link" : "sparkles" }
}

struct SettingsView: View {
  @Environment(ConnectionStore.self) private var connections
  @Environment(TelegramSession.self) private var telegram
  @Environment(\.dismiss) private var dismiss
  @State private var connecting: ConnectionService?
  @State private var showTelegram = false
  @AppStorage("settings.selectedSection") private var selectedSection = "connections"

  private var sections: [WorkspaceSettingsSection] {
    ResearchProvider.enabledInBuild ? WorkspaceSettingsSection.allCases : [.connections]
  }

  private var section: WorkspaceSettingsSection {
    sections.first { $0.rawValue == selectedSection } ?? .connections
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      HStack(spacing: 0) {
        if sections.count > 1 {
          navigation
          Divider()
        }
        ScrollView {
          Group {
            switch section {
            case .connections: connectionSettings
            case .research: ResearchSettingsView()
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(22)
        }
        .scrollBounceBehavior(.basedOnSize)
      }
    }
    .frame(width: sections.count > 1 ? 680 : 520, height: 550)
    .background(TerminalStyle.canvas)
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

  private var header: some View {
    HStack {
      Text("Settings").font(AppTypography.bodySemibold).accessibilityAddTraits(.isHeader)
      Spacer()
      Button { dismiss() } label: {
        Image(systemName: "xmark").frame(width: 26, height: 26).contentShape(Rectangle())
      }
      .buttonStyle(.plain).foregroundStyle(.secondary)
      .keyboardShortcut(.cancelAction)
      .accessibilityLabel("Close Settings")
    }
    .padding(.horizontal, 16).frame(height: 40)
    .background { WorkspaceChrome(region: .toolbar) }
  }

  private var navigation: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(sections) { item in
        let selected = section == item
        Button {
          selectedSection = item.rawValue
        } label: {
          HStack(spacing: 9) {
            Image(systemName: item.icon).frame(width: 18)
            Text(item.title).font(AppTypography.calloutMedium)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 10).frame(height: 34)
        }
        .buttonStyle(TerminalControlStyle(
          fill: selected ? TerminalStyle.accent : .clear,
          foreground: selected ? .white : .secondary,
          border: selected ? TerminalStyle.accent : .clear,
          glass: selected ? .init(tint: TerminalStyle.accent) : nil))
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(width: 158)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background { WorkspaceChrome(region: .sidebar) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Settings sections")
  }

  private var connectionSettings: some View {
    VStack(alignment: .leading, spacing: 16) {
      SettingsHeading(title: "Connections", subtitle: "Connect accounts for portfolio and market context.")
      VStack(spacing: 8) {
        ForEach(ConnectionService.allCases) { service in
          ConnectionSettingsRow(session: connections.session(for: service)) { connecting = service }
        }
        TelegramSettingsRow(session: telegram) {
          showTelegram = true
          telegram.connect()
        }
      }
      Text("Manage signing wallets from the Wallet menu.")
        .font(AppTypography.caption).foregroundStyle(.secondary)
    }
  }
}

struct SettingsHeading: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(AppTypography.font(size: 22, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text(subtitle).font(AppTypography.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct SettingsServiceIcon: View {
  var artwork: String?
  let symbol: String

  var body: some View {
    Group {
      if let artwork {
        OnboardingArtwork(name: artwork)
      } else {
        Image(systemName: symbol).font(.system(size: 15, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 28, height: 28)
    .background(TerminalStyle.panel, in: RoundedRectangle(cornerRadius: 7))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .accessibilityHidden(true)
  }
}

struct SettingsConnectedBadge: View {
  var body: some View {
    Label("Connected", systemImage: "checkmark.circle.fill")
      .font(AppTypography.caption)
      .foregroundStyle(TerminalStyle.buy)
      .padding(.horizontal, 7).padding(.vertical, 4)
      .background(TerminalStyle.buy.opacity(0.09), in: Capsule())
  }
}

struct SettingsProfileLink: View {
  let title: String
  let service: String
  let destination: URL

  var body: some View {
    Link(destination: destination) {
      HStack(spacing: 4) {
        Text(verbatim: title).lineLimit(1)
        Image(systemName: "arrow.up.right")
          .font(AppTypography.caption)
          .accessibilityHidden(true)
      }
      .foregroundStyle(Color.blue)
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens the \(service) profile")
    .help("Open \(service) profile")
  }
}

extension View {
  func settingsCard() -> some View {
    let shape = RoundedRectangle(cornerRadius: 10)
    return padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(TerminalStyle.panel, in: shape)
      .overlay { shape.strokeBorder(TerminalStyle.border).allowsHitTesting(false) }
  }

  func settingsActionLabel() -> some View {
    font(AppTypography.caption).padding(.horizontal, 10).frame(height: 29)
  }
}

private struct ConnectionSettingsRow: View {
  let session: ConnectionBrowserSession
  let connect: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        SettingsServiceIcon(artwork: session.service == .pump ? "pumpfun" : "fomo",
          symbol: "person.crop.circle")
        Text(session.service.name).font(AppTypography.bodySemibold)
        Spacer()
        if session.isReading {
          ProgressView().controlSize(.small)
        } else if session.profile != nil {
          SettingsConnectedBadge()
        }
        if session.profile == nil {
          Button(action: connect) {
            Text("Connect \(session.service.name)").settingsActionLabel()
          }.buttonStyle(TerminalControlStyle.primary).disabled(session.isReading)
        }
      }
      if let profile = session.profile {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
          GridRow {
            Text("Username").foregroundStyle(.secondary)
            if let destination = session.service.profileURL(for: profile) {
              SettingsProfileLink(
                title: profile.username.map { "@\($0)" } ?? "View profile",
                service: session.service.name, destination: destination
              )
            } else {
              Text(verbatim: profile.username.map { "@\($0)" } ?? "Not set")
                .textSelection(.enabled)
            }
          }
          GridRow {
            Text("Wallet").foregroundStyle(.secondary)
            Text(verbatim: profile.wallet).font(AppTypography.caption).monospaced()
              .textSelection(.enabled).lineLimit(2)
          }
        }
        .font(AppTypography.callout)
        HStack {
          Text("Checked \(profile.checkedAt.formatted(date: .omitted, time: .shortened))")
            .font(AppTypography.caption).foregroundStyle(.secondary)
          Spacer()
          Button { session.refresh() } label: {
            Text("Refresh").settingsActionLabel()
          }
          Button { Task { await session.disconnect() } } label: {
            Text("Disconnect").settingsActionLabel()
          }
        }
        .buttonStyle(TerminalControlStyle()).disabled(session.isReading)
      }
      if let error = session.error {
        Text(error).font(AppTypography.callout).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .settingsCard()
  }
}
