import AppKit
import SwiftUI

struct WalletSetupView: View {
  @Environment(WalletStore.self) private var store
  let onComplete: (TradingWallet) -> Void
  let onCancel: () -> Void

  private enum Step { case choice, backup, verify, phrase, key, preview }
  @State private var step = Step.choice
  @State private var importStep = Step.phrase
  @State private var input = ""
  @State private var passphrase = ""
  @State private var index = ""
  @State private var family = WalletFamily.solana
  @State private var secret: WalletSecret?
  @State private var accounts: [WalletAccount] = []
  @State private var reveal = false
  @State private var copied = false
  @State private var challenges: [Int] = []
  @State private var answers: [Int: String] = [:]
  @State private var error: String?
  @State private var busy = false
  @State private var generation = UUID()
  @State private var work: Task<Void, Never>?

  private var words: [Substring] { secret?.value.split(separator: " ") ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      switch step {
      case .choice: choice
      case .backup: backup
      case .verify: verify
      case .phrase, .key: importForm
      case .preview: preview
      }
      if let error { Text(error).font(AppTypography.caption).foregroundStyle(.orange) }
    }
    .padding(18)
    .frame(width: 390)
    .background(TerminalStyle.panel)
    .onDisappear {
      work?.cancel()
      clearSecrets()
    }
  }

  private var choice: some View {
    VStack(alignment: .leading, spacing: 10) {
      header("Add a wallet")
      option("Create wallet", detail: "New Solana and EVM accounts", icon: "wallet.bifold") {
        run {
          let (value, addresses) = try await WalletDerivation.generate()
          try Task.checkCancellation()
          secret = value
          accounts = addresses
          challenges = Array(0..<12).shuffled().prefix(3).sorted()
          step = .backup
        }
      }
      option("Import recovery phrase", detail: "Restore your accounts", icon: "arrow.counterclockwise") {
        step = .phrase
      }
      option("Import private key", detail: "Add a single account", icon: "key") {
        step = .key
      }
      HStack {
        if busy { ProgressView().controlSize(.small) }
        Spacer()
        Button(action: onCancel) {
          Text("Cancel").font(AppTypography.calloutMedium).padding(.horizontal, 12).frame(height: 34)
        }.buttonStyle(TerminalControlStyle())
      }
    }
  }

  private var backup: some View {
    VStack(alignment: .leading, spacing: 10) {
      header("Back up your wallet")
      Text("Save these words in order to restore your wallet on another Mac.")
        .font(AppTypography.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
        ForEach(words.indices, id: \.self) { i in
          HStack(spacing: 6) {
            Text("\(i + 1)").foregroundStyle(.secondary).monospacedDigit()
            Text(verbatim: reveal ? String(words[i]) : "••••••")
          }
          .font(AppTypography.caption).monospaced().frame(maxWidth: .infinity, minHeight: 32)
          .background(TerminalStyle.canvas, in: RoundedRectangle(cornerRadius: 6))
        }
      }
      .walletCard(padding: 8)
      HStack(spacing: 8) {
        Button { reveal.toggle() } label: {
          Label(reveal ? "Hide phrase" : "Reveal phrase", systemImage: reveal ? "eye.slash" : "eye")
            .font(AppTypography.calloutMedium).frame(maxWidth: .infinity).frame(height: 34)
        }
        Button { copyPhrase() } label: {
          Label(copied ? "Copied" : "Copy phrase", systemImage: copied ? "checkmark" : "document.on.document")
            .font(AppTypography.calloutMedium).frame(maxWidth: .infinity).frame(height: 34)
        }.disabled(secret == nil)
      }
      .buttonStyle(TerminalControlStyle())
      footer(back: reset, action: "Verify backup", enabled: reveal || copied) {
        reveal = false
        step = .verify
      }
    }
  }

  private var verify: some View {
    VStack(alignment: .leading, spacing: 10) {
      header("Verify your backup")
      Text("Enter the requested words from your backup.")
        .font(AppTypography.callout).foregroundStyle(.secondary)
      ForEach(challenges, id: \.self) { i in
        VStack(alignment: .leading, spacing: 5) {
          Text("Word \(i + 1)").font(AppTypography.caption).foregroundStyle(.secondary)
          SecureField("Enter word", text: Binding(
            get: { answers[i, default: ""] }, set: { answers[i] = $0 }))
            .walletField()
            .accessibilityLabel("Word \(i + 1)")
        }
      }
      footer(back: { answers = [:]; step = .backup }, action: "Create wallet",
        enabled: challenges.allSatisfy { !(answers[$0] ?? "").isEmpty }) {
        guard challenges.allSatisfy({ answers[$0]?.trimmingCharacters(in: .whitespaces) == String(words[$0]) }) else {
          error = "Check the requested words and try again."
          return
        }
        save()
      }
    }
  }

  private var importForm: some View {
    let byPhrase = step == .phrase
    return VStack(alignment: .leading, spacing: 12) {
      header(byPhrase ? "Import recovery phrase" : "Import private key")
      if !byPhrase {
        WalletFamilyTabs(families: WalletFamily.allCases, selection: $family)
          .disabled(busy)
      }
      SecureField(byPhrase ? "Recovery phrase" : "Private key", text: $input)
        .walletField()
        .disabled(busy)
      if byPhrase {
        DisclosureGroup("Recovery options") {
          VStack(alignment: .leading, spacing: 8) {
            SecureField("Optional BIP39 passphrase", text: $passphrase)
              .walletField()
            TextField("Account index (0 by default)", text: $index)
              .walletField()
          }.padding(.top, 8).disabled(busy)
        }
      }
      footer(back: reset, action: "Preview accounts", enabled: !input.isEmpty) {
        let rawIndex = index.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawIndex.isEmpty || UInt32(rawIndex).map({ $0 < (1 << 31) }) == true else {
          error = "Enter a valid account index."
          return
        }
        let value = WalletSecret(kind: byPhrase ? .phrase : .privateKey, value: input,
          family: byPhrase ? nil : family, passphrase: byPhrase ? passphrase : nil,
          accountIndex: byPhrase ? UInt32(rawIndex) : nil)
        run {
          let addresses = try await WalletDerivation.inspect(value)
          try Task.checkCancellation()
          secret = value
          accounts = addresses
          input = ""; passphrase = ""
          importStep = step
          step = .preview
        }
      }
    }
  }

  private var preview: some View {
    VStack(alignment: .leading, spacing: 10) {
      header("Confirm wallet import")
      Text("Check that these match your existing accounts.")
        .font(AppTypography.callout).foregroundStyle(.secondary)
      ForEach(accounts) { account in
        VStack(alignment: .leading, spacing: 5) {
          Text(account.family.title).font(AppTypography.caption).foregroundStyle(.secondary)
          Text(verbatim: account.address).font(.system(size: 10, design: .monospaced))
            .textSelection(.enabled)
        }
        .walletCard(padding: 10)
      }
      footer(back: { secret = nil; accounts = []; step = importStep }, action: "Confirm import") { save() }
    }
  }

  private func header(_ title: String) -> some View {
    Text(title).font(AppTypography.headline).accessibilityAddTraits(.isHeader)
  }

  private func option(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: icon).frame(width: 22)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(AppTypography.calloutMedium)
          Text(detail).font(AppTypography.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right").foregroundStyle(.secondary)
      }
      .walletCard(padding: 10)
      .contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(busy)
  }

  private func footer(back: @escaping () -> Void, action: String, enabled: Bool = true,
    next: @escaping () -> Void) -> some View {
    HStack(spacing: 8) {
      Button { error = nil; back() } label: {
        Text("Back").font(AppTypography.calloutMedium).padding(.horizontal, 13).frame(height: 34)
      }.buttonStyle(TerminalControlStyle()).disabled(busy)
      if busy { ProgressView().controlSize(.small) }
      Button(action: next) {
        Text(action).font(AppTypography.calloutMedium)
          .frame(maxWidth: .infinity).frame(height: 34)
      }.buttonStyle(TerminalControlStyle.primary).disabled(!enabled || busy)
    }.padding(.top, 4)
  }

  private func run(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true; error = nil
    let id = generation
    work = Task {
      defer { if generation == id { busy = false; work = nil } }
      do { try await operation() }
      catch is CancellationError { }
      catch { if !Task.isCancelled, generation == id { self.error = error.localizedDescription } }
    }
  }

  private func save() {
    guard let secret else { return }
    run {
      let wallet = try await store.add(secret, accounts: accounts)
      try Task.checkCancellation()
      clearSecrets()
      onComplete(wallet)
    }
  }

  private func copyPhrase() {
    guard let phrase = secret?.value else { return }
    copied = Self.copyBackupPhrase(phrase, to: .general)
    error = copied ? nil : "Couldn’t copy the recovery phrase."
  }

  static func copyBackupPhrase(_ phrase: String, to pasteboard: NSPasteboard) -> Bool {
    let item = NSPasteboardItem()
    item.setString(phrase, forType: .string)
    item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
  }

  private func reset() {
    clearSecrets()
    step = .choice
  }

  private func clearSecrets() {
    generation = UUID()
    input = ""; passphrase = ""; index = ""
    secret = nil; accounts = []; answers = [:]; challenges = []
    reveal = false; copied = false; busy = false; work = nil
  }
}
