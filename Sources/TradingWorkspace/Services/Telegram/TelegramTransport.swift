import Darwin
import Foundation

enum TelegramError: LocalizedError {
  case libraryUnavailable, libraryInvalid, invalidResponse, timeout, sessionClosed
  case requestFailed(Int, String?)
  case configuration, storage, keychain

  var errorDescription: String? {
    switch self {
    case .libraryUnavailable: "This build is missing Telegram support."
    case .libraryInvalid: "The bundled Telegram library could not load."
    case .invalidResponse: "Telegram returned an unexpected response."
    case .timeout: "Telegram did not respond. Try again."
    case .sessionClosed: "The Telegram session closed."
    case .requestFailed(let code, _):
      code == 429 ? "Telegram is limiting requests. Try again shortly." : "Telegram could not complete this request."
    case .configuration: "Telegram app credentials are missing or invalid."
    case .storage: "The local Telegram session could not be opened."
    case .keychain: "The Telegram session key is unavailable in Keychain."
    }
  }
}

/// Every Telegram request the app can make. The surface contains no message writes
/// or calls that mark messages as read.
enum TelegramMethod: String, Sendable {
  case getOption, setOption, setTdlibParameters, requestQrCodeAuthentication
  case setAuthenticationPhoneNumber, checkAuthenticationCode, checkAuthenticationPassword
  case setAuthenticationEmailAddress, checkAuthenticationEmailCode
  case getMe, searchMessages, getChat, getUser, getForumTopic, getChatHistory, getForumTopicHistory, getMessage
  case getMessageLink, logOut, close
}

@MainActor
protocol TelegramRequesting: AnyObject {
  func request(
    _ method: TelegramMethod, _ fields: [String: TelegramJSON]
  ) async throws -> TelegramJSON
}

extension TelegramRequesting {
  func request(_ method: TelegramMethod) async throws -> TelegramJSON {
    try await request(method, [:])
  }
}

/// The C API requires one receive caller per process. The reader owns that thread
/// and copies each borrowed packet before the next call. The stream preserves order.
final class TDLibRuntime: @unchecked Sendable {
  private typealias Create = @convention(c) () -> Int32
  private typealias Send = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void
  private typealias Receive = @convention(c) (Double) -> UnsafePointer<CChar>?
  private typealias Execute = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

  private let createClient: Create
  private let sendRequest: Send
  private let receive: Receive
  private let execute: Execute
  private let stopped = NSLock()
  private var didStop = false

  init(library: URL) throws {
    guard FileManager.default.fileExists(atPath: library.path) else {
      throw TelegramError.libraryUnavailable
    }
    guard let handle = dlopen(library.path, RTLD_NOW | RTLD_LOCAL) else {
      throw TelegramError.libraryInvalid
    }
    guard let create = dlsym(handle, "td_create_client_id"),
      let send = dlsym(handle, "td_send"),
      let receive = dlsym(handle, "td_receive"),
      let execute = dlsym(handle, "td_execute")
    else {
      dlclose(handle)
      throw TelegramError.libraryInvalid
    }
    // Keep TDLib resident. Its worker threads can outlive a disconnected client.
    createClient = unsafeBitCast(create, to: Create.self)
    sendRequest = unsafeBitCast(send, to: Send.self)
    self.receive = unsafeBitCast(receive, to: Receive.self)
    self.execute = unsafeBitCast(execute, to: Execute.self)
    _ = "{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":0}".withCString {
      self.execute($0)
    }
  }

  func makeClient() -> Int32 { createClient() }

  func send(_ body: TelegramJSON, to client: Int32) throws {
    let data = try JSONEncoder().encode(body)
    let value = String(decoding: data, as: UTF8.self)
    value.withCString { sendRequest(client, $0) }
  }

  func packets() -> AsyncStream<TelegramJSON> {
    let (stream, continuation) = AsyncStream<TelegramJSON>.makeStream()
    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      stopped.withLock { didStop = true }
    }
    Thread.detachNewThread { [self] in
      let decoder = JSONDecoder()
      while !stopped.withLock({ didStop }) {
        guard let bytes = receive(1) else { continue }
        let data = Data(bytes: bytes, count: strlen(bytes))
        if let packet = try? decoder.decode(TelegramJSON.self, from: data) {
          continuation.yield(packet)
        }
      }
      continuation.finish()
    }
    return stream
  }
}

@MainActor
final class TelegramTransport: TelegramRequesting {
  private struct Pending {
    let continuation: CheckedContinuation<TelegramJSON, any Error>
    let timeout: Task<Void, Never>
  }

  private let runtime: TDLibRuntime
  private var reader: Task<Void, Never>?
  private var pending: [String: Pending] = [:]
  private var clientID: Int32?
  var onUpdate: ((TelegramJSON) -> Void)?

  init(library: URL) throws {
    runtime = try TDLibRuntime(library: library)
    let packets = runtime.packets()
    reader = Task { [weak self] in
      for await packet in packets {
        guard let self else { return }
        receive(packet)
      }
    }
  }

  deinit { reader?.cancel() }

  func startClient() {
    precondition(clientID == nil)
    clientID = runtime.makeClient()
  }

  func request(
    _ method: TelegramMethod, _ fields: [String: TelegramJSON]
  ) async throws -> TelegramJSON {
    guard let clientID else { throw TelegramError.sessionClosed }
    let requestID = UUID().uuidString
    var parameters = fields
    parameters["@extra"] = .string(requestID)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        let timeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(20)) } catch { return }
          self?.complete(requestID, .failure(TelegramError.timeout))
        }
        pending[requestID] = Pending(continuation: continuation, timeout: timeout)
        do { try runtime.send(.object(method.rawValue, parameters), to: clientID) }
        catch { complete(requestID, .failure(error)) }
      }
    } onCancel: {
      Task { @MainActor in self.complete(requestID, .failure(CancellationError())) }
    }
  }

  private func receive(_ packet: TelegramJSON) {
    guard let clientID, packet["@client_id"].int == Int64(clientID) else { return }
    if let extra = packet["@extra"].string {
      let result: Result<TelegramJSON, any Error>
      if packet.type == "error" {
        // TDLib messages may contain sign-in inputs. Expose only normalized errors.
        let reason = packet["message"].string
        let safeReasons = ["PHONE_NUMBER_INVALID", "PHONE_CODE_INVALID", "PHONE_CODE_EXPIRED",
          "PASSWORD_HASH_INVALID", "EMAIL_INVALID", "EMAIL_VERIFY_EXPIRED", "EMAIL_CODE_INVALID",
          "API_ID_INVALID"]
        result = .failure(TelegramError.requestFailed(
          Int(clamping: packet["code"].int ?? 0),
          reason.flatMap { safeReasons.contains($0) ? $0 : nil }))
      } else {
        result = .success(packet)
      }
      complete(extra, result)
    } else {
      if packet["authorization_state"].type == "authorizationStateClosed" {
        self.clientID = nil
        for extra in Array(pending.keys) {
          complete(extra, .failure(TelegramError.sessionClosed))
        }
      }
      onUpdate?(packet)
    }
  }

  private func complete(_ key: String, _ result: Result<TelegramJSON, any Error>) {
    guard let entry = pending.removeValue(forKey: key) else { return }
    entry.timeout.cancel()
    entry.continuation.resume(with: result)
  }
}
