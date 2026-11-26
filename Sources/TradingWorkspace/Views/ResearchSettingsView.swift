import SwiftUI

struct ResearchSettingsView: View {
  private let providers = ResearchProviders.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top) {
        SettingsHeading(title: "AI Providers", subtitle: "Use an AI account already signed in on this Mac.")
        Spacer()
        Button {
          Task { await providers.detect() }
        } label: {
          Label("Detect again", systemImage: "arrow.clockwise").settingsActionLabel()
        }.buttonStyle(TerminalControlStyle())
      }
      if let error = providers.serviceError {
        Text(error).font(AppTypography.callout).foregroundStyle(.orange)
      }
      VStack(spacing: 8) {
        ForEach(ResearchProvider.allCases) { provider in row(provider) }
      }
      Text("Research tools run locally. Your selected AI provider receives the tool results it uses to answer.")
        .font(AppTypography.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .task { await providers.detect() }
  }

  private func row(_ provider: ResearchProvider) -> some View {
    let installed = providers.installed[provider]
    let catalog = providers.catalogs[provider]
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        SettingsServiceIcon(
          artwork: provider == .codex ? "codex" : provider == .grok ? "grok" : nil,
          symbol: "sparkles")
        VStack(alignment: .leading, spacing: 3) {
          Text(provider.name).font(AppTypography.bodySemibold)
          if let catalog { Text("\(catalog.models.count) models").foregroundStyle(.secondary) }
        }
        Spacer()
        if providers.checking.contains(provider) {
          ProgressView().controlSize(.small)
        } else if catalog != nil {
          SettingsConnectedBadge()
          Button {
            Task { await providers.check(provider) }
          } label: {
            Text("Check again").settingsActionLabel()
          }.buttonStyle(TerminalControlStyle())
        } else if installed == true {
          Button {
            Task { await providers.check(provider) }
          } label: {
            Text("Use existing sign-in").settingsActionLabel()
          }.buttonStyle(TerminalControlStyle.primary)
        } else if installed == false {
          Link(destination: provider.setupURL) {
            Label("Install \(provider.name)", systemImage: "arrow.up.right").settingsActionLabel()
          }.buttonStyle(TerminalControlStyle())
        }
      }
      if let error = providers.connectionErrors[provider] {
        Text(error).foregroundStyle(.orange)
        HStack {
          Text("Sign-in command").foregroundStyle(.secondary)
          Text(provider.signInCommand).monospaced().textSelection(.enabled)
        }
        .padding(8).background(TerminalStyle.field, in: RoundedRectangle(cornerRadius: 6))
      }
    }
    .font(AppTypography.caption)
    .settingsCard()
  }
}
