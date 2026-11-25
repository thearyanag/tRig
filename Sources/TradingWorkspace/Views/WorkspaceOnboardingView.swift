import AppKit
import SwiftUI

enum WorkspaceOnboardingStep: Int, CaseIterable {
  case markets = 1
  case connections
  case research

  var title: String {
    switch self {
    case .markets: "Find a market"
    case .connections: "Connect your accounts"
    case .research: "Automate your research"
    }
  }

  var description: String {
    switch self {
    case .markets: "Search by name or paste a contract address."
    case .connections: "Bring your portfolio and Telegram discussion into tRig."
    case .research: "Use an AI subscription you already have to research the token you’re viewing."
    }
  }

  var previous: Self? { Self(rawValue: rawValue - 1) }
  var next: Self? { Self(rawValue: rawValue + 1) }
}

struct WorkspaceOnboardingView: View {
  @Binding var step: WorkspaceOnboardingStep
  let onFinish: () -> Void

  private var next: WorkspaceOnboardingStep? {
    if step == .connections && !ResearchProvider.enabledInBuild { return nil }
    return step.next
  }

  var body: some View {
    ZStack {
      Color.black.opacity(0.48).ignoresSafeArea().accessibilityHidden(true)
      card
    }
    .accessibilityAddTraits(.isModal)
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("\(step.rawValue) of \(ResearchProvider.enabledInBuild ? WorkspaceOnboardingStep.allCases.count : 2)")
          .monospacedDigit()
        Spacer()
        Button("Skip tour", action: onFinish)
          .buttonStyle(.plain).keyboardShortcut(.cancelAction)
      }
      .font(AppTypography.font(size: 16))
      .foregroundStyle(.white.opacity(0.92))
      .padding(.bottom, 2)

      VStack(alignment: .leading, spacing: 6) {
        Text(step.title).font(AppTypography.font(size: 31, weight: .bold))
          .accessibilityAddTraits(.isHeader)
        Text(step.description).font(AppTypography.font(size: 16))
          .foregroundStyle(.white.opacity(0.92))
          .fixedSize(horizontal: false, vertical: true)
      }
      preview
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      VStack(spacing: 10) {
        Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
        HStack {
          if let previous = step.previous {
            Button { step = previous } label: {
              Text("Back").frame(width: 96, height: 40)
            }
            .buttonStyle(TerminalControlStyle(fill: TerminalStyle.panel, border: .white.opacity(0.18)))
          }
          Spacer()
          Button {
            if let next { step = next } else { onFinish() }
          } label: {
            Text(next == nil ? "Finish" : "Next").frame(width: 108, height: 40)
          }
          .buttonStyle(TerminalControlStyle(fill: TerminalStyle.accent, border: TerminalStyle.accent))
          .keyboardShortcut(.defaultAction)
        }
        .font(AppTypography.font(size: 16, weight: .medium))
      }
    }
    .padding(.horizontal, 28).padding(.vertical, 22)
    .frame(width: 634, height: 448, alignment: .topLeading)
    .background(OnboardingPalette.card, in: RoundedRectangle(cornerRadius: 15))
    .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.28)))
    .shadow(color: .black.opacity(0.38), radius: 24, y: 10)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("tRig welcome tour")
  }

  @ViewBuilder private var preview: some View {
    switch step {
    case .markets: OnboardingMarketPreview()
    case .connections: OnboardingConnectionsPreview()
    case .research: OnboardingResearchPreview()
    }
  }
}

private enum OnboardingPalette {
  static let card = Color(red: 0.059, green: 0.091, blue: 0.118)
  static let inset = Color(red: 0.042, green: 0.065, blue: 0.084)
  static let control = Color(red: 0.073, green: 0.105, blue: 0.13)
  static let line = Color.white.opacity(0.22)
}

private struct OnboardingArtwork: View {
  let name: String

  var body: some View {
    if let url = Bundle.main.resourceURL?.appendingPathComponent("Onboarding/\(name).png"),
      let image = NSImage(contentsOf: url) {
      Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
    }
  }
}

private struct OnboardingMarketPreview: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("Example search").font(AppTypography.font(size: 14))
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass")
          Text("Search markets or paste a CA…")
          Spacer()
          HStack(spacing: 3) {
            keycap("⌘")
            keycap("K")
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Command K")
        }
        .font(AppTypography.font(size: 16))
        .padding(.horizontal, 10)
        .frame(height: 39)
        .background(OnboardingPalette.control, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(OnboardingPalette.line))
        .padding(.bottom, 6)

        marketRow("Backpack", symbol: "BP", network: "Solana", networkIcon: "solana-network") {
          AssetIconView(asset: .backpack)
        }
        Rectangle().fill(OnboardingPalette.line).frame(height: 1).padding(.horizontal, 3)
        marketRow("Wrapped Ether", symbol: "WETH", network: "Base", networkIcon: "base-network") {
          OnboardingArtwork(name: "weth")
        }
      }
      .padding(.horizontal, 16).padding(.vertical, 11)
      .background(OnboardingPalette.inset, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(OnboardingPalette.line))
    }
    .padding(.horizontal, 15)
  }

  private func keycap(_ text: String) -> some View {
    Text(verbatim: text).font(AppTypography.font(size: 13)).frame(width: 24, height: 24)
      .background(TerminalStyle.panel, in: RoundedRectangle(cornerRadius: 4))
  }

  private func marketRow<Icon: View>(
    _ name: String, symbol: String, network: String, networkIcon: String, @ViewBuilder icon: () -> Icon
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      icon()
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(name).font(AppTypography.font(size: 17, weight: .semibold))
          Text(symbol).font(AppTypography.font(size: 14)).foregroundStyle(.white.opacity(0.9))
        }
        HStack(spacing: 6) {
          OnboardingArtwork(name: networkIcon).frame(width: 16, height: 16).accessibilityHidden(true)
          Text(network).font(AppTypography.font(size: 14))
        }
      }
      Spacer()
    }
    .padding(.horizontal, 10).frame(height: 54)
  }
}

private struct OnboardingConnectionsPreview: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 16) {
        service("Pumpfun", artwork: "pumpfun")
        service("Fomo", artwork: "fomo")
        service("Telegram", artwork: "telegram")
      }
      Rectangle().fill(OnboardingPalette.line).frame(height: 1)
      HStack(spacing: 14) {
        Image(systemName: "lock").font(.system(size: 17)).accessibilityHidden(true)
        Rectangle().fill(OnboardingPalette.line).frame(width: 1, height: 27)
        VStack(alignment: .leading, spacing: 3) {
          Text("Sessions stay on this Mac.")
          Text("tRig connects directly to the services you choose.")
        }
        .font(AppTypography.font(size: 14))
      }
      .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, 5)
  }

  private func service(_ title: String, artwork: String) -> some View {
    VStack(spacing: 10) {
      OnboardingArtwork(name: artwork)
        .frame(width: 46, height: 46)
        .accessibilityHidden(true)
      Text(title).font(AppTypography.font(size: 16, weight: .medium))
    }
    .frame(maxWidth: .infinity)
    .frame(height: 124)
    .background(OnboardingPalette.inset, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(OnboardingPalette.line))
  }
}

private struct OnboardingResearchPreview: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Example research").font(AppTypography.font(size: 14))
        Spacer()
        Text("Planned").font(AppTypography.font(size: 12)).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 12) {
          provider("Codex", artwork: "codex")
          provider("Claude", artwork: "claude")
          provider("Grok", artwork: "grok")
          provider("Gemini", artwork: "gemini")
        }
        .padding(.vertical, 12)
        Rectangle().fill(OnboardingPalette.line).frame(height: 1)
        HStack(alignment: .top, spacing: 14) {
          Text("Research task").font(AppTypography.font(size: 15, weight: .medium))
            .frame(width: 160, alignment: .leading)
          Text("Compare the launch announcement with liquidity and recent trades.")
            .font(AppTypography.font(size: 15))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
      }
      .padding(.horizontal, 15)
      .background(OnboardingPalette.inset, in: RoundedRectangle(cornerRadius: 9))
      .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(OnboardingPalette.line))
      Text("You choose what to share with your AI provider.")
        .font(AppTypography.font(size: 14))
    }
    .padding(.horizontal, 9)
  }

  private func provider(_ name: String, artwork: String) -> some View {
    VStack(spacing: 5) {
      OnboardingArtwork(name: artwork).frame(width: 30, height: 30)
        .accessibilityHidden(true)
      Text(name).font(AppTypography.font(size: 13, weight: .medium))
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}
