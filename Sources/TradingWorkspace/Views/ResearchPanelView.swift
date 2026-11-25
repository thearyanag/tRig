import SwiftUI

struct ResearchPanelView: View {
  let asset: Asset
  @Binding var expanded: Bool
  @Binding var question: String
  @Environment(ResearchConversationStore.self) private var chat
  @Environment(TelegramSession.self) private var telegram
  @Environment(\.openSettings) private var openSettings
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @AppStorage("settings.selectedSection") private var settingsSection = "connections"
  @AppStorage("research.lastProvider") private var preferredProvider = ResearchProvider.codex
  @State private var model: String?
  @FocusState private var composing: Bool
  private let providers = ResearchProviders.shared

  private var provider: ResearchProvider { chat.conversation?.provider ?? preferredProvider }
  private var hasConversation: Bool { chat.conversation != nil || chat.isResponding }
  private var canSend: Bool {
    chat.restored && !chat.isResponding && (chat.conversation != nil || providers.catalogs[provider] != nil)
      && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && question.count <= 8000
  }

  var body: some View {
    VStack(spacing: 0) {
      if expanded {
        VStack(spacing: 0) {
          header
          Divider().padding(.horizontal, 12)
          transcript
          if let error = chat.error {
            HStack {
              Text(error).foregroundStyle(.orange).textSelection(.enabled)
              Spacer(minLength: 4)
              if !chat.restored {
                Button("Retry") { Task { await chat.restore() } }.buttonStyle(.link)
              }
            }
            .font(AppTypography.caption).padding([.horizontal, .bottom], 12)
          }
        }
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .offset(y: 8)))
      }
      composer
    }
    .background {
      if expanded {
        let shape = RoundedRectangle(cornerRadius: 22)
        shape.fill(reduceTransparency ? TerminalStyle.panel : TerminalStyle.panel.opacity(0.92))
          .background(.regularMaterial, in: shape)
          .overlay { shape.strokeBorder(.white.opacity(0.17)) }
          .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
          .allowsHitTesting(false)
      }
    }
    .frame(maxWidth: 590)
    .task(id: provider) { await providers.restore(provider) }
    .onChange(of: chat.conversation?.id, initial: true) { _, _ in model = chat.conversation?.model }
    .onChange(of: composing) { _, focused in
      if focused && (hasConversation || chat.error != nil) { setExpanded(true) }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text("Research").font(AppTypography.bodySemibold)
      Text("\(asset.symbol) · \(asset.network)")
        .font(AppTypography.caption).foregroundStyle(.secondary).lineLimit(1)
      Spacer(minLength: 6)
      Button {
        composing = false
        setExpanded(false)
      } label: {
        Image(systemName: "chevron.down").frame(width: 30, height: 28).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Collapse Research").help("Collapse Research")
    }
    .padding(.leading, 14).padding(.trailing, 7).frame(height: 36)
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 9) {
          ForEach(chat.messages) { message in
            messageRow(message)
          }
          if chat.restoring {
            ProgressView("Restoring Research…").controlSize(.small)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          Color.clear.frame(height: 1).id("research-bottom").accessibilityHidden(true)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
      }
      .defaultScrollAnchor(.bottom)
      .frame(height: 147)
      .onChange(of: chat.messages.count) { _, _ in proxy.scrollTo("research-bottom", anchor: .bottom) }
      .onChange(of: chat.messages.last?.text.count) { _, _ in
        if chat.isResponding { proxy.scrollTo("research-bottom", anchor: .bottom) }
      }
    }
  }

  private func messageRow(_ message: ResearchMessage) -> some View {
    Group {
      if message.role == .user {
        Text(verbatim: message.text).textSelection(.enabled)
          .padding(.horizontal, 10).padding(.vertical, 6)
          .background(TerminalStyle.accent.opacity(0.26), in: RoundedRectangle(cornerRadius: 12))
          .frame(maxWidth: .infinity, alignment: .trailing)
      } else if message.role == .error {
        Text(verbatim: message.text).foregroundStyle(.orange).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else if message.text.isEmpty {
        ProgressView().controlSize(.small)
          .accessibilityLabel("Research is responding")
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ResearchMarkdownView(text: message.text).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var composer: some View {
    HStack(spacing: 9) {
      Button {
        if expanded {
          composing = false
          setExpanded(false)
        } else if hasConversation || chat.restoring || chat.error != nil {
          setExpanded(true)
        } else {
          composing = true
        }
      } label: {
        Image(systemName: "sparkles").foregroundStyle(.secondary)
          .frame(width: 27, height: 28).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(expanded ? "Hide Research conversation" : "Open Research")
      if chat.isResponding && !expanded {
        Button {
          setExpanded(true)
        } label: {
          Text("Response in progress…")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Research response")
      } else {
        TextField(expanded && hasConversation ? "Ask a follow-up…" : "Ask about \(asset.symbol)…", text: $question)
          .textFieldStyle(.plain)
          .focused($composing)
          .accessibilityLabel("Research question")
          .help("Ask about \(asset.name) on \(asset.network)")
          .onSubmit(sendQuestion)
          .disabled(chat.isResponding)
      }
      providerMenu
      Button {
        if chat.isResponding { Task { await chat.stop() } }
        else { sendQuestion() }
      } label: {
        Image(systemName: chat.isResponding ? "stop.fill" : "arrow.up")
          .font(.system(size: 13, weight: .semibold))
          .frame(width: 30, height: 30)
          .foregroundStyle(.white)
          .background(.blue.opacity(actionEnabled ? 1 : 0.35), in: Circle())
      }
      .buttonStyle(.plain).disabled(!actionEnabled)
      .accessibilityLabel(chat.isResponding ? "Stop response" : "Send research question")
      .help(chat.isResponding ? "Stop response" : "Send")
    }
    .padding(.leading, 9).padding(.trailing, 7).frame(height: 44)
    .background(TerminalStyle.field.opacity(reduceTransparency ? 1 : 0.7), in: Capsule())
    .overlay { Capsule().strokeBorder(.white.opacity(0.15)).allowsHitTesting(false) }
    .modifier(ResearchComposerGlass(enabled: !reduceTransparency))
  }

  private var actionEnabled: Bool {
    chat.isResponding ? chat.canStop && !chat.stopping : canSend
  }

  private var providerMenu: some View {
    Menu {
      if chat.conversation == nil {
        Picker("Provider", selection: $preferredProvider) {
          ForEach(ResearchProvider.allCases) { Text($0.name).tag($0) }
        }
      }
      if let models = providers.catalogs[provider]?.models, !models.isEmpty {
        Picker("Model", selection: $model) {
          if chat.conversation?.model == nil { Text("Default model").tag(nil as String?) }
          if let model, !models.contains(where: { $0.id == model }) { Text(verbatim: model).tag(Optional(model)) }
          ForEach(models) { Text($0.name).tag(Optional($0.id)) }
        }
      }
      Button("AI Provider Settings…") {
        settingsSection = "research"
        openSettings()
      }
    } label: {
      Text(provider.name).font(AppTypography.caption)
    }
    .menuStyle(.borderlessButton).fixedSize()
    .accessibilityLabel(chat.conversation == nil ? "Research provider" : "\(provider.name), model options")
    .help(chat.conversation == nil ? "Choose an AI provider" : "Provider is fixed for this conversation")
    .disabled(chat.isResponding || chat.restoring)
    .onChange(of: preferredProvider) { _, _ in
      if chat.conversation == nil { model = nil }
    }
  }

  private func sendQuestion() {
    guard canSend else { return }
    chat.send(asset: asset, provider: provider, model: model,
      question: question.trimmingCharacters(in: .whitespacesAndNewlines), telegram: telegram)
    question = ""
    setExpanded(true)
  }

  private func setExpanded(_ visible: Bool) {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
      expanded = visible
    }
  }
}

private struct ResearchComposerGlass: ViewModifier {
  let enabled: Bool

  func body(content: Content) -> some View {
    if enabled {
      content.terminalGlass(.init(tint: TerminalStyle.panel.opacity(0.38), cornerRadius: 22), interactive: false)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    } else {
      content
    }
  }
}
