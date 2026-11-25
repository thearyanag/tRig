import SwiftUI

struct ResearchSettingsView: View {
  private let providers = ResearchProviders.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("AI Providers").font(AppTypography.title2Semibold)
          Text("Use the account already signed in on this Mac.")
            .font(AppTypography.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Detect again") { Task { await providers.detect() } }
      }
      Text("Research tools run locally. Your selected AI provider receives the tool results it uses to answer.")
        .font(AppTypography.caption).foregroundStyle(.secondary)
      if let error = providers.serviceError {
        Text(error).font(AppTypography.callout).foregroundStyle(.orange)
      }
      ForEach(ResearchProvider.allCases) { provider in row(provider) }
    }
    .task { await providers.detect() }
  }

  private func row(_ provider: ResearchProvider) -> some View {
    let installed = providers.installed[provider]
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(provider.name).font(AppTypography.bodySemibold)
        Spacer()
        if providers.checking.contains(provider) {
          ProgressView().controlSize(.small)
        } else if let catalog = providers.catalogs[provider] {
          Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          Text("\(catalog.models.count) models").foregroundStyle(.secondary)
          Button("Check again") { Task { await providers.check(provider) } }
        } else if installed == true {
          Button("Use existing sign-in") { Task { await providers.check(provider) } }
        } else if installed == false {
          Link("Install \(provider.name)", destination: provider.setupURL)
        }
      }
      if let error = providers.connectionErrors[provider] {
        Text(error).foregroundStyle(.orange)
        HStack {
          Text("Sign-in command").foregroundStyle(.secondary)
          Text(provider.signInCommand).monospaced().textSelection(.enabled)
        }
      }
    }
    .font(AppTypography.caption)
    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    .background(TerminalStyle.panel, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TerminalStyle.border))
  }
}
