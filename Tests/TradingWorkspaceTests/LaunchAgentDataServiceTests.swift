import Foundation
import Testing

@testable import TradingWorkspace

@Test @MainActor func launchAgentReconnectsWithoutRestartingItsClient() async throws {
  let first = try #require(URL(string: "http://127.0.0.1:12345/first/"))
  let second = try #require(URL(string: "http://127.0.0.1:12346/second/"))
  let fixture = LaunchAgentEndpointFixture(url: first)
  let service = LaunchAgentDataService(
    probe: { fixture.url }, pollInterval: .milliseconds(10), connectionTimeout: .seconds(1))

  #expect(try await service.readyURL() == first)
  fixture.url = nil
  let deadline = ContinuousClock.now + .seconds(1)
  while service.baseURL != nil && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(service.baseURL == nil)
  #expect(service.error != nil)

  fixture.url = second
  #expect(try await service.readyURL() == second)
  #expect(service.error == nil)
}

@Test func launchAgentEndpointRejectsInvalidDiscoveryData() async throws {
  typealias Endpoint = LaunchAgentDataService.Endpoint
  let token = String(repeating: "ab", count: 16)
  #expect(Endpoint(port: 12345, pid: 1, token: token).baseURL?.absoluteString
    == "http://127.0.0.1:12345/\(token)/")
  #expect(Endpoint(port: 0, pid: 1, token: token).baseURL == nil)
  #expect(Endpoint(port: 12345, pid: 0, token: token).baseURL == nil)
  #expect(Endpoint(port: 12345, pid: 1, token: "../" + token).baseURL == nil)
}

@MainActor private final class LaunchAgentEndpointFixture {
  var url: URL?
  init(url: URL?) { self.url = url }
}
