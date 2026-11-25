import Foundation
import OSLog
import Observation

@MainActor
protocol LocalDataServiceConnection: AnyObject {
  var baseURL: URL? { get }
  var error: String? { get }
  func readyURL() async throws -> URL
  func start()
  func reconnect()
}

/// Owns the Rust sidecar in packaged releases.
@MainActor @Observable
final class LocalDataService: LocalDataServiceConnection {
  static let shared: any LocalDataServiceConnection = {
    if Bundle.main.object(forInfoDictionaryKey: "TRIGUseDataLaunchAgent") as? Bool == true {
      return LaunchAgentDataService()
    }
    return LocalDataService()
  }()
  private(set) var baseURL: URL?
  private(set) var error: String?

  private struct StartupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }
  private typealias Readiness = AsyncStream<Result<URL, Error>>

  @ObservationIgnored private let makeProcess: @MainActor () throws -> Process
  @ObservationIgnored private let startupLimit: Duration
  @ObservationIgnored private var process: Process?
  @ObservationIgnored private var output: Pipe?
  @ObservationIgnored private var errors: Pipe?
  @ObservationIgnored private var buffer = Data()
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var startupTimeout: Task<Void, Never>?
  @ObservationIgnored private var readinessWaiters: [UUID: Readiness.Continuation] = [:]
  @ObservationIgnored private let logger = Logger(
    subsystem: "com.aryan.TradingWorkspace", category: "LocalDataService")

  init(
    makeProcess: @escaping @MainActor () throws -> Process = LocalDataService.makeBundledProcess,
    startupLimit: Duration = .seconds(15)
  ) {
    self.makeProcess = makeProcess
    self.startupLimit = startupLimit
  }

  func readyURL() async throws -> URL {
    try Task.checkCancellation()
    if let baseURL { return baseURL }

    let id = UUID()
    let (stream, waiter) = Readiness.makeStream()
    readinessWaiters[id] = waiter
    defer { readinessWaiters.removeValue(forKey: id) }
    start()
    var iterator = stream.makeAsyncIterator()
    guard let result = await iterator.next() else { throw CancellationError() }
    try Task.checkCancellation()
    let url = try result.get()
    guard baseURL == url else {
      if let error { throw StartupError(message: error) }
      throw CancellationError()
    }
    return url
  }

  private static func makeBundledProcess() throws -> Process {
    guard let resources = Bundle.main.resourceURL else {
      throw StartupError(message: "Chart resources are unavailable. Run the app using its build script.")
    }
    let binary = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Helpers/trading-data-service")
    let assets = resources.appendingPathComponent("Chart")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
      throw StartupError(message: "The local data service is missing. Rebuild the app.")
    }
    guard
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else {
      throw StartupError(message: "Application Support is unavailable. The data service could not start.")
    }
    let directory = support.appendingPathComponent("com.aryan.TradingWorkspace", isDirectory: true)
    let child = Process()
    child.executableURL = binary
    child.arguments = [
      "--assets", assets.path,
      "--database", directory.appendingPathComponent("portfolio.sqlite").path,
      "--quote-config", directory.appendingPathComponent("quotes.env").path,
      "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
    ]
    return child
  }

  func start() {
    guard process == nil else { return }
    error = nil
    let token = UUID()
    generation = token
    let child: Process
    do {
      child = try makeProcess()
    } catch {
      fail(error.localizedDescription)
      return
    }
    let stdout = Pipe()
    let stderr = Pipe()
    child.standardOutput = stdout
    child.standardError = stderr
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { @MainActor [weak self] in self?.receive(data, token: token) }
    }
    stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard let message = String(data: data, encoding: .utf8), !message.isEmpty else { return }
      Task { @MainActor [weak self] in self?.logger.error("\(message, privacy: .public)") }
    }
    child.terminationHandler = { [weak self] terminated in
      let status = terminated.terminationStatus
      Task { @MainActor [weak self] in
        guard let self, self.generation == token else { return }
        self.fail("The local data service stopped (\(status)). Retry to reconnect.")
      }
    }
    process = child
    output = stdout
    errors = stderr
    do {
      try child.run()
      startupTimeout = Task { [weak self, startupLimit] in
        do { try await Task.sleep(for: startupLimit) } catch { return }
        guard !Task.isCancelled, let self, self.generation == token, self.baseURL == nil else { return }
        self.fail("The local data service did not start. Retry to reconnect.")
      }
    } catch {
      fail("Could not start the local data service: \(error.localizedDescription)")
    }
  }

  func restart() {
    stop()
    start()
  }

  func reconnect() { restart() }

  func stop() {
    clearProcess()
    error = nil
    finishStartup(with: .failure(CancellationError()))
  }

  private func receive(_ data: Data, token: UUID) {
    guard generation == token, baseURL == nil else { return }
    buffer.append(data)
    guard let newline = buffer.firstIndex(of: 10) else { return }
    let line = Data(buffer.prefix(upTo: newline))
    buffer.removeAll()
    struct Ready: Decodable { let port: Int }
    guard let ready = try? JSONDecoder().decode(Ready.self, from: line),
      (1...65535).contains(ready.port),
      let url = URL(string: "http://127.0.0.1:\(ready.port)/")
    else {
      fail("The local data service returned an invalid startup response.")
      return
    }
    baseURL = url
    finishStartup(with: .success(url))
  }

  private func fail(_ message: String) {
    clearProcess()
    error = message
    finishStartup(with: .failure(StartupError(message: message)))
  }

  private func finishStartup(with result: Result<URL, Error>) {
    startupTimeout?.cancel()
    startupTimeout = nil
    let waiters = readinessWaiters
    readinessWaiters.removeAll()
    for waiter in waiters.values {
      waiter.yield(result)
      waiter.finish()
    }
  }

  private func clearProcess() {
    generation = UUID()
    process?.terminationHandler = nil
    if process?.isRunning == true { process?.terminate() }
    output?.fileHandleForReading.readabilityHandler = nil
    errors?.fileHandleForReading.readabilityHandler = nil
    output = nil
    errors = nil
    process = nil
    baseURL = nil
    buffer.removeAll()
  }
}
