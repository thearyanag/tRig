import SwiftUI

struct SupportPanelView: View {
  private enum Page: Equatable {
    case issues, compose, conversation(SupportIssue.ID)
  }

  private enum Field: Hashable {
    case subject, description, reply
  }

  @Binding var isOpen: Bool
  var store = SupportIssueStore.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @FocusState private var focusedField: Field?
  @State private var page = Page.issues
  @State private var subject = ""
  @State private var description = ""
  @State private var reply = ""
  @State private var saveFailed = false

  var body: some View {
    Group {
      if isOpen { panel.transition(.opacity.combined(with: .offset(y: 5))) }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isOpen)
    .onChange(of: isOpen) { _, open in
      if !open { showIssues() }
    }
  }

  private var panel: some View {
    let shape = RoundedRectangle(cornerRadius: 15)
    return VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      switch page {
      case .issues:
        issueList
      case .compose:
        form
      case .conversation(let id):
        if let issue = store.issues.first(where: { $0.id == id }) {
          conversation(issue)
        }
      }
      Divider()
      Text(saveFailed ? "Couldn’t save on this Mac. Try again." : "Saved on this Mac · Nothing is sent")
        .font(AppTypography.caption)
        .foregroundStyle(saveFailed ? Color.orange : .secondary)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
    .font(AppTypography.body)
    .frame(width: 356)
    .background {
      shape.fill(TerminalStyle.quotePanel.opacity(reduceTransparency ? 1 : 0.82))
        .background {
          if !reduceTransparency { shape.fill(.regularMaterial) }
        }
        .overlay(shape.strokeBorder(.white.opacity(0.16)))
    }
    .shadow(color: .black.opacity(0.44), radius: 15, y: 6)
  }

  private var header: some View {
    HStack(spacing: 8) {
      if page != .issues {
        iconButton("chevron.left", label: "Back to issues") { showIssues() }
      }
      Text(title)
        .font(AppTypography.font(size: 16, weight: .semibold))
        .lineLimit(1)
        .help(title)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 4)
      iconButton("xmark", label: "Close support") { isOpen = false }
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 12).frame(height: 44)
  }

  private var title: String {
    switch page {
    case .issues: "tRig Support"
    case .compose: "New issue"
    case .conversation(let id): store.issues.first(where: { $0.id == id })?.subject ?? "Issue"
    }
  }

  private var issueList: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Your issues").font(AppTypography.bodySemibold)
        Spacer()
        Button {
          page = .compose
        } label: {
          Label("New issue", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .tint(TerminalStyle.accent)
        .disabled(store.loadFailed)
      }
      .padding(.horizontal, 16).frame(height: 44)

      if store.issues.isEmpty {
        Text(store.loadFailed ? "Saved issues couldn’t be loaded." : "No issues yet")
          .font(AppTypography.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 68)
          .padding(.bottom, 8)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(store.issues) { issue in
              Divider()
              Button {
                reply = ""
                page = .conversation(issue.id)
              } label: {
                HStack(spacing: 12) {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(issue.subject).font(AppTypography.bodySemibold).lineLimit(1)
                    if let latest = issue.messages.last {
                      Text(latest.date.formatted(date: .abbreviated, time: .omitted))
                        .font(AppTypography.caption).foregroundStyle(.secondary)
                    }
                  }
                  Spacer(minLength: 0)
                  Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 53, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, 16)
        }
        .frame(height: min(CGFloat(store.issues.count) * 55, 244))
      }
    }
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Subject").font(AppTypography.calloutMedium)
      TextField("", text: $subject)
        .textFieldStyle(.plain)
        .padding(9)
        .background(fieldBackground)
        .focused($focusedField, equals: .subject)
        .accessibilityLabel("Subject")
      Text("Describe the issue").font(AppTypography.calloutMedium).padding(.top, 3)
      TextEditor(text: $description)
        .scrollContentBackground(.hidden)
        .padding(6)
        .frame(height: 94)
        .background(fieldBackground)
        .focused($focusedField, equals: .description)
        .accessibilityLabel("Describe the issue")
      Button(action: createIssue) {
        Text("Create issue").frame(maxWidth: .infinity).frame(height: 34)
      }
      .buttonStyle(TerminalControlStyle.primary)
      .disabled(trimmed(subject).isEmpty || trimmed(description).isEmpty)
    }
    .padding(16)
    .task {
      await Task.yield()
      if !Task.isCancelled { focusedField = .subject }
    }
  }

  private func conversation(_ issue: SupportIssue) -> some View {
    VStack(spacing: 0) {
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .trailing, spacing: 10) {
            ForEach(issue.messages) { message in
              VStack(alignment: .trailing, spacing: 4) {
                Text(message.date.formatted(date: .abbreviated, time: .shortened))
                  .font(AppTypography.caption).foregroundStyle(.secondary)
                Text(message.text)
                  .textSelection(.enabled)
                  .padding(10)
                  .background(TerminalStyle.accent.opacity(0.26), in: RoundedRectangle(cornerRadius: 10))
              }
              .id(message.id)
            }
          }
          .frame(maxWidth: .infinity, alignment: .trailing)
          .padding(16)
        }
        .frame(height: 202)
        .onChange(of: issue.messages.last?.id, initial: true) { _, id in
          if let id { reader.scrollTo(id, anchor: .bottom) }
        }
      }
      HStack(alignment: .bottom, spacing: 8) {
        TextField("Write a reply…", text: $reply, axis: .vertical)
          .textFieldStyle(.plain).lineLimit(1...4)
          .padding(9).background(fieldBackground)
          .focused($focusedField, equals: .reply)
        Button {
          saveReply(for: issue.id)
        } label: {
          Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
            .frame(width: 30, height: 30)
            .foregroundStyle(.white)
            .background(TerminalStyle.accent, in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(trimmed(reply).isEmpty ? 0.45 : 1)
        .disabled(trimmed(reply).isEmpty)
        .accessibilityLabel("Save reply")
        .help("Save reply on this Mac")
      }
      .padding(.horizontal, 16).padding(.bottom, 12)
    }
  }

  private var fieldBackground: some View {
    let shape = RoundedRectangle(cornerRadius: 7)
    return shape.fill(TerminalStyle.field.opacity(0.75)).overlay(shape.strokeBorder(TerminalStyle.border))
  }

  private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        .frame(width: 26, height: 26).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .help(label)
  }

  private func showIssues() {
    focusedField = nil
    saveFailed = false
    page = .issues
  }

  private func createIssue() {
    do {
      let id = try store.create(subject: trimmed(subject), message: trimmed(description))
      subject = ""
      description = ""
      reply = ""
      focusedField = nil
      saveFailed = false
      page = .conversation(id)
    } catch {
      saveFailed = true
    }
  }

  private func saveReply(for id: SupportIssue.ID) {
    do {
      try store.reply(to: id, message: trimmed(reply))
      reply = ""
      saveFailed = false
    } catch {
      saveFailed = true
    }
  }

  private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
