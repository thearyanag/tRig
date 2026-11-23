import Foundation
import Testing

@testable import TradingWorkspace

@MainActor
private final class SidecarFixture {
  private var input: Pipe?
  private(set) var launches = 0

  func makeProcess() -> Process {
    let pipe = Pipe()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", #"""
      IFS= read -r line || exit 7
      printf '%s\n' "$line"
      IFS= read -r _
      """#]
    child.standardInput = pipe
    input = pipe
    launches += 1
    return child
  }

  func send(_ reply: String) throws {
    let pipe = try #require(input)
    try pipe.fileHandleForWriting.write(contentsOf: Data((reply + "\n").utf8))
  }

  func exitBeforeReady() throws {
    try #require(input).fileHandleForWriting.close()
  }

  func awaitLaunch() async throws {
    for _ in 0..<1000 {
      if launches > 0 { return }
      await Task.yield()
    }
    try #require(launches > 0)
  }
}

@Test @MainActor func waitersShareAStartupAndCancelIndependently() async throws {
  let fixture = SidecarFixture()
  let service = LocalDataService(makeProcess: fixture.makeProcess, startupLimit: .seconds(3))
  defer { service.stop() }
  let cancelled = Task { try await service.readyURL() }
  try await fixture.awaitLaunch()
  let first = Task { try await service.readyURL() }
  let second = Task { try await service.readyURL() }
  cancelled.cancel()
  await #expect(throws: CancellationError.self) { try await cancelled.value }
  #expect(service.baseURL == nil)
  try fixture.send(#"{"port":12345}"#)

  let endpoint = try #require(URL(string: "http://127.0.0.1:12345/"))
  #expect(try await first.value == endpoint)
  #expect(try await second.value == endpoint)
  #expect(try await service.readyURL() == endpoint)
  #expect(fixture.launches == 1)
}

@Test @MainActor func invalidStartupReleasesWaitersAndAllowsRetry() async throws {
  let fixture = SidecarFixture()
  let service = LocalDataService(makeProcess: fixture.makeProcess, startupLimit: .seconds(3))
  defer { service.stop() }
  let pending = Task { try await service.readyURL() }
  try await fixture.awaitLaunch()
  try fixture.send(#"{"port":0}"#)
  if case .failure(let error) = await pending.result {
    #expect(error.localizedDescription.contains("invalid startup response"))
  } else {
    Issue.record("Invalid startup response produced an endpoint")
  }

  service.restart()
  let retry = Task { try await service.readyURL() }
  try fixture.send(#"{"port":23456}"#)
  #expect(try await retry.value.port == 23456)
  #expect(service.error == nil)
  #expect(fixture.launches == 2)
}

@Test @MainActor func startupExitAndTimeoutReleaseWaiters() async throws {
  for shouldExit in [true, false] {
    let fixture = SidecarFixture()
    let service = LocalDataService(
      makeProcess: fixture.makeProcess, startupLimit: shouldExit ? .seconds(3) : .milliseconds(100))
    defer { service.stop() }
    let pending = Task { try await service.readyURL() }
    try await fixture.awaitLaunch()
    if shouldExit { try fixture.exitBeforeReady() }
    guard case .failure(let error) = await pending.result else {
      Issue.record("Failed startup produced an endpoint")
      continue
    }
    #expect(error.localizedDescription.contains(shouldExit ? "stopped (7)" : "did not start"))
    #expect(service.error == error.localizedDescription)
  }
}

@Test @MainActor func stoppingDuringStartupCancelsPendingRequests() async throws {
  let fixture = SidecarFixture()
  let service = LocalDataService(makeProcess: fixture.makeProcess, startupLimit: .seconds(3))
  defer { service.stop() }
  let pending = Task { try await service.readyURL() }
  try await fixture.awaitLaunch()

  service.stop()

  await #expect(throws: CancellationError.self) { try await pending.value }
  #expect(service.baseURL == nil && service.error == nil)
}
