import Foundation
import Observation

/// Discovers the development service without managing the launchd job from Swift.
@MainActor @Observable
final class LaunchAgentDataService: LocalDataServiceConnection {
  private static let unavailable =
    "The local data service is unavailable. Run script/data_service.sh status to check it."

  struct Endpoint: Decodable {
    let port: UInt16
    let pid: Int
    let token: String

    var baseURL: URL? {
      guard port != 0, pid > 0, token.utf8.count == 32,
        token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { return nil }
      return URL(string: "http://127.0.0.1:\(port)/\(token)/")
    }
  }

  private struct Health: Decodable {
    let status: String
    let pid: Int
  }

  private(set) var baseURL: URL?
  private(set) var error: String?
  @ObservationIgnored private var monitor: Task<Void, Never>?
  @ObservationIgnored private let probe: @MainActor () async -> URL?
  @ObservationIgnored private let pollInterval: Duration
  @ObservationIgnored private let connectionTimeout: Duration

  init(
    probe: @escaping @MainActor () async -> URL? = { await LaunchAgentDataService.probeEndpoint() },
    pollInterval: Duration = .seconds(2), connectionTimeout: Duration = .seconds(15)
  ) {
    self.probe = probe
    self.pollInterval = pollInterval
    self.connectionTimeout = connectionTimeout
  }

  func start() {
    guard monitor == nil else { return }
    monitor = Task { [weak self, probe, pollInterval] in
      while !Task.isCancelled {
        let url = await probe()
        guard !Task.isCancelled, let self else { return }
        let error = url == nil ? Self.unavailable : nil
        if self.baseURL != url { self.baseURL = url }
        if self.error != error { self.error = error }
        do { try await Task.sleep(for: pollInterval) } catch { return }
      }
    }
  }

  func reconnect() {
    monitor?.cancel()
    monitor = nil
    start()
  }

  func readyURL() async throws -> URL {
    start()
    let deadline = ContinuousClock.now + connectionTimeout
    repeat {
      try Task.checkCancellation()
      if let baseURL { return baseURL }
      try await Task.sleep(for: .milliseconds(100))
    } while ContinuousClock.now < deadline
    throw LocalBackendClient.RequestError(message: Self.unavailable)
  }

  private static let endpointFile = URL.applicationSupportDirectory
    .appending(path: "com.aryan.TradingWorkspace/DataService/endpoint.json")

  private static let healthSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.connectionProxyDictionary = [:]
    return URLSession(configuration: config)
  }()

  private static func probeEndpoint() async -> URL? {
    guard let bytes = try? Data(contentsOf: endpointFile),
      let endpoint = try? JSONDecoder().decode(Endpoint.self, from: bytes),
      let url = endpoint.baseURL
    else { return nil }
    let request = URLRequest(
      url: url.appending(path: "api/health"), cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 1)
    guard let (data, response) = try? await healthSession.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      response.url == request.url,
      let health = try? JSONDecoder().decode(Health.self, from: data),
      health.status == "ok", health.pid == endpoint.pid
    else { return nil }
    return url
  }
}
