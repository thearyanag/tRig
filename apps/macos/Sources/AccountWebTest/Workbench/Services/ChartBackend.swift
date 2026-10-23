import Foundation
import OSLog
import Observation

/// One app-owned Rust process, shared by chart windows. No provider requests in Swift.
@MainActor @Observable
final class ChartBackend {
  static let shared = ChartBackend()
  private(set) var baseURL: URL?
  private(set) var error: String?

  @ObservationIgnored private var process: Process?
  @ObservationIgnored private var output: Pipe?
  @ObservationIgnored private var errors: Pipe?
  @ObservationIgnored private var buffer = Data()
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var startupTimeout: Task<Void, Never>?
  @ObservationIgnored private let logger = Logger(
    subsystem: "local.trig.ChartBackend", category: "ChartBackend")

  func start() {
    guard process == nil else { return }
    error = nil
    buffer = Data()
    let token = UUID()
    generation = token
    guard let resources = Bundle.main.resourceURL else {
      error = "Chart resources are unavailable. Run the app using its build script."
      return
    }
    let binary = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Helpers/trading-data-service")
    let assets = resources.appendingPathComponent("Chart")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
      error = "The chart service is missing. Rebuild the app."
      return
    }
    let child = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    child.executableURL = binary
    child.arguments = [
      "--assets", assets.path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
    ]
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
        self.clearHandles()
        self.baseURL = nil
        self.error = "The chart service stopped (\(status)). Retry to reconnect."
      }
    }
    process = child
    output = stdout
    errors = stderr
    do {
      try child.run()
      startupTimeout = Task { [weak self] in
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled, let self, self.generation == token, self.baseURL == nil else {
          return
        }
        self.stop()
        self.error = "The chart service did not start. Retry to reconnect."
      }
    } catch {
      clearHandles()
      self.error = "Could not start the chart service: \(error.localizedDescription)"
    }
  }

  func restart() {
    stop()
    start()
  }

  func stop() {
    generation = UUID()
    startupTimeout?.cancel()
    process?.terminationHandler = nil
    if process?.isRunning == true { process?.terminate() }
    clearHandles()
    baseURL = nil
  }

  private func receive(_ data: Data, token: UUID) {
    guard generation == token else { return }
    buffer.append(data)
    guard let newline = buffer.firstIndex(of: 10) else { return }
    let line = Data(buffer.prefix(upTo: newline))
    buffer.removeSubrange(...newline)
    struct Ready: Decodable { let port: Int }
    guard let ready = try? JSONDecoder().decode(Ready.self, from: line),
      (1...65535).contains(ready.port)
    else {
      stop()
      error = "The chart service returned an invalid startup response."
      return
    }
    baseURL = URL(string: "http://127.0.0.1:\(ready.port)/")
    startupTimeout?.cancel()
  }

  private func clearHandles() {
    startupTimeout?.cancel()
    output?.fileHandleForReading.readabilityHandler = nil
    errors?.fileHandleForReading.readabilityHandler = nil
    output = nil
    errors = nil
    process = nil
  }
}
