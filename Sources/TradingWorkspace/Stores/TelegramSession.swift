import Foundation
import Observation

@MainActor @Observable
final class TelegramSession {
  enum Phase: Equatable {
    case disconnected, starting, phone, code, email, emailCode, password
    case qr(String), ready, closing, unsupported
  }

  static let shared = TelegramSession()
  private static let slotKey = "telegram.sessionSlot"
  private static let authorizedKey = "telegram.hadSession"

  private(set) var phase: Phase = .disconnected
  private(set) var accountName: String?
  private(set) var issue: String?
  private(set) var busy = false
  private(set) var epoch = UUID()
  struct Change: Equatable {
    var id = UUID()
    let messages: Set<TelegramQuote.ID>
  }
  private(set) var lastChange: Change?

  @ObservationIgnored private var transport: TelegramTransport?
  @ObservationIgnored private var startParameters: [String: TelegramJSON]?
  @ObservationIgnored private var active = false
  @ObservationIgnored private var offerQR = false
  @ObservationIgnored private var removeAfterLogout = false
  @ObservationIgnored private var hasRestored = false
  @ObservationIgnored private var slot: UUID?
  @ObservationIgnored private var lifecycle = UUID()
  @ObservationIgnored private var authRequest: Task<Void, Never>?
  @ObservationIgnored private var profileRequest: Task<Void, Never>?
  @ObservationIgnored private var changeSequence: Int = 0
  @ObservationIgnored private var changedMessages: [TelegramQuote.ID: Int] = [:]
  @ObservationIgnored private let files = TelegramSessionFiles(root: TelegramSessionFiles.appSupport)
  @ObservationIgnored private let preferences = UserDefaults.standard

  var isConnected: Bool { phase == .ready }
  var needsGracefulClose: Bool { active }
  var configurationAvailable: Bool { (try? TelegramAppCredentials.load(at: files.configuration)) != nil }

  func restore() {
    guard !hasRestored else { return }
    hasRestored = true
    if preferences.bool(forKey: Self.authorizedKey) {
      start(showQR: false)
    }
  }

  func connect() {
    issue = nil
    guard !active else {
      if phase == .phone { requestQR() }
      return
    }
    start(showQR: true)
  }

  private func start(showQR: Bool) {
    guard !active else { return }
    issue = nil
    do {
      let credentials = try TelegramAppCredentials.load(at: files.configuration)
      let directory = files.root
      let frameworkDirectory = Bundle.main.privateFrameworksURL
        ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
      let library = frameworkDirectory.appendingPathComponent("libtdjson.dylib")
      if transport == nil {
        let client = try TelegramTransport(library: library)
        client.onUpdate = { [weak self] packet in self?.receive(packet) }
        transport = client
      }
      guard let transport else { throw TelegramError.libraryUnavailable }
      let slot = preferences.string(forKey: Self.slotKey).flatMap(UUID.init(uuidString:)) ?? UUID()
      // Persist the local slot before creating encrypted files so an interrupted setup is retryable.
      preferences.set(slot.uuidString, forKey: Self.slotKey)
      self.slot = slot
      let lifecycle = UUID()
      self.lifecycle = lifecycle
      phase = .starting
      offerQR = showQR
      active = true
      authRequest = Task { [weak self] in
        // Keychain may ask for permission on a rebuilt app. Keep that off the UI thread.
        let parameters = await Task.detached {
          Result { try TelegramSessionFiles(root: directory).parameters(for: slot, credentials: credentials) }
        }.value
        guard let self, self.lifecycle == lifecycle, self.phase == .starting else { return }
        switch parameters {
        case .success(let parameters):
          startParameters = parameters
          transport.startClient()
          perform(.getOption, ["name": .string("version")])
        case .failure(let error):
          active = false
          phase = .disconnected
          issue = error.localizedDescription
        }
      }
    } catch {
      phase = .disconnected
      issue = error.localizedDescription
    }
  }

  func requestQR() {
    guard phase == .phone else { return }
    perform(.requestQrCodeAuthentication, ["other_user_ids": .array([])])
  }

  func usePhoneInstead() async {
    guard case .qr = phase else { return }
    await close()
    if !active { start(showQR: false) }
  }

  func submit(_ input: String) {
    let value = phase == .password ? input : input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    switch phase {
    case .phone: perform(.setAuthenticationPhoneNumber, ["phone_number": .string(value)])
    case .code: perform(.checkAuthenticationCode, ["code": .string(value)])
    case .email: perform(.setAuthenticationEmailAddress, ["email_address": .string(value)])
    case .emailCode:
      perform(.checkAuthenticationEmailCode,
        ["code": .object("emailAddressAuthenticationCode", ["code": .string(value)])])
    case .password: perform(.checkAuthenticationPassword, ["password": .string(value)])
    default: break
    }
  }

  func disconnect() {
    guard isConnected, !busy else { return }
    perform(.logOut)
  }

  func close() async {
    guard active, let transport else { return }
    offerQR = false
    if phase == .starting, startParameters == nil {
      lifecycle = UUID()
      authRequest?.cancel()
      active = false
      busy = false
      phase = .disconnected
      return
    }
    let old = phase
    phase = .closing
    epoch = UUID()
    do { _ = try await transport.request(.close) }
    catch TelegramError.sessionClosed { return }
    catch {
      if phase == .closing {
        phase = old
        issue = error.localizedDescription
      }
      return
    }
    for _ in 0..<50 where active {
      try? await Task.sleep(for: .milliseconds(100))
    }
    if active { issue = "Telegram is still closing. Try again shortly." }
  }

  func discussion(for asset: Asset, offset: String = "") async throws -> TelegramDiscussionPage {
    guard isConnected, let transport else { throw TelegramError.sessionClosed }
    let current = epoch
    let started = changeSequence
    let result = try await TelegramDiscussionClient(transport: transport).page(for: asset, offset: offset)
    try Task.checkCancellation()
    guard isConnected, epoch == current else { throw TelegramError.sessionClosed }
    let changed = Set(changedMessages.filter { $0.value > started }.keys)
    return changed.isEmpty ? result : result.removingChangedMessages(changed)
  }

  func context(for exchange: TelegramExchange, asset: Asset, includeSurrounding: Bool)
    async throws -> TelegramExchangeContext
  {
    guard isConnected, let transport else { throw TelegramError.sessionClosed }
    let current = epoch
    let started = changeSequence
    let result = try await TelegramDiscussionClient(transport: transport)
      .context(for: exchange, asset: asset, includeSurrounding: includeSurrounding)
    try Task.checkCancellation()
    guard isConnected, epoch == current else { throw TelegramError.sessionClosed }
    guard changedMessages[exchange.id, default: 0] <= started else {
      throw TelegramError.invalidResponse
    }
    let unaffected: (TelegramQuote) -> Bool = { self.changedMessages[$0.id, default: 0] <= started }
    return TelegramExchangeContext(parent: result.parent.flatMap { unaffected($0) ? $0 : nil },
      replies: result.replies.filter(unaffected), before: result.before.filter(unaffected),
      after: result.after.filter(unaffected))
  }

  func link(for id: TelegramQuote.ID) async throws -> URL {
    guard isConnected, let transport else { throw TelegramError.sessionClosed }
    let current = epoch
    let url = try await TelegramDiscussionClient(transport: transport).messageLink(id)
    try Task.checkCancellation()
    guard isConnected, epoch == current else { throw TelegramError.sessionClosed }
    return url
  }

  private func perform(_ method: TelegramMethod, _ fields: [String: TelegramJSON] = [:]) {
    guard let transport else { return }
    authRequest?.cancel()
    busy = true
    issue = nil
    let started = phase
    let lifecycle = lifecycle
    authRequest = Task { [weak self] in
      defer { if self?.lifecycle == lifecycle && !Task.isCancelled { self?.busy = false } }
      do { _ = try await transport.request(method, fields) }
      catch {
        guard !Task.isCancelled, let self, self.lifecycle == lifecycle, phase == started else { return }
        issue = Self.loginIssue(error)
        if method == .logOut { removeAfterLogout = false }
        if method == .getOption || method == .setTdlibParameters {
          await close()
        }
      }
    }
  }

  private func receive(_ packet: TelegramJSON) {
    switch packet.type {
    case "updateAuthorizationState": updateAuthorization(packet["authorization_state"])
    case "updateMessageContent", "updateDeleteMessages":
      guard isConnected, let id = packet["chat_id"].int else { return }
      if packet.type == "updateDeleteMessages", packet["from_cache"].bool == true { return }
      let messages = packet["message_ids"].array?.compactMap(\.int)
        ?? packet["message_id"].int.map { [$0] } ?? []
      if !messages.isEmpty {
        let changes = Set(messages.map { TelegramQuote.ID(chat: id, message: $0) })
        changeSequence &+= 1
        for message in changes { changedMessages[message] = changeSequence }
        if changedMessages.count > 1000 {
          changedMessages = changedMessages.filter { $0.value > changeSequence - 100 }
        }
        lastChange = Change(messages: changes)
      }
    default: break
    }
  }

  private func updateAuthorization(_ state: TelegramJSON) {
    switch state.type {
    case "authorizationStateWaitTdlibParameters":
      if let startParameters { perform(.setTdlibParameters, startParameters) }
    case "authorizationStateWaitPhoneNumber":
      phase = .phone
      if offerQR { offerQR = false; requestQR() }
    case "authorizationStateWaitOtherDeviceConfirmation":
      if let link = state["link"].string, link.hasPrefix("tg://login?token="), link.utf8.count < 2048 {
        phase = .qr(link)
      } else {
        issue = "Telegram could not provide a QR code."
      }
    case "authorizationStateWaitCode": phase = .code
    case "authorizationStateWaitEmailAddress": phase = .email
    case "authorizationStateWaitEmailCode": phase = .emailCode
    case "authorizationStateWaitPassword": phase = .password
    case "authorizationStateReady":
      startParameters = nil
      phase = .ready
      epoch = UUID()
      preferences.set(true, forKey: Self.authorizedKey)
      readProfile()
    case "authorizationStateLoggingOut":
      removeAfterLogout = true
      phase = .closing
      accountName = nil
      epoch = UUID()
    case "authorizationStateClosing": phase = .closing
    case "authorizationStateClosed":
      active = false
      phase = .disconnected
      busy = false
      startParameters = nil
      lifecycle = UUID()
      epoch = UUID()
      accountName = nil
      profileRequest?.cancel()
      changedMessages.removeAll()
      lastChange = nil
      if removeAfterLogout, let slot {
        removeAfterLogout = false
        preferences.removeObject(forKey: Self.authorizedKey)
        preferences.removeObject(forKey: Self.slotKey)
        do { try files.remove(slot) }
        catch { issue = error.localizedDescription }
      }
    case "authorizationStateWaitRegistration", "authorizationStateWaitPremiumPurchase":
      phase = .unsupported
    default: break
    }
  }

  private func readProfile() {
    guard let transport else { return }
    profileRequest?.cancel()
    let epoch = epoch
    profileRequest = Task { [weak self] in
      guard let user = try? await transport.request(.getMe),
        let self, self.epoch == epoch, isConnected else { return }
      let name = [user["first_name"].string, user["last_name"].string]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
      accountName = name.isEmpty ? nil : name
    }
  }

  private static func loginIssue(_ error: any Error) -> String {
    if case TelegramError.requestFailed(_, let reason) = error {
      switch reason {
      case "PHONE_NUMBER_INVALID": return "Enter a phone number in international format."
      case "PHONE_CODE_INVALID", "EMAIL_CODE_INVALID": return "That code did not match. Try again."
      case "PHONE_CODE_EXPIRED", "EMAIL_VERIFY_EXPIRED": return "The code expired. Start sign-in again."
      case "PASSWORD_HASH_INVALID": return "The two-step verification password did not match."
      case "EMAIL_INVALID": return "Enter a valid email address."
      case "API_ID_INVALID": return "Telegram rejected the app credentials."
      default: break
      }
    }
    return error.localizedDescription
  }
}
