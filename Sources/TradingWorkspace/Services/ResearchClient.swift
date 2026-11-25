import Foundation

@MainActor
enum ResearchClient {
  private struct Empty: Decodable {}
  private struct Failure: Decodable { let error: String }

  static func installations() async throws -> [ResearchInstallation] { try await request("providers") }

  static func probe(_ provider: ResearchProvider) async throws -> ResearchCatalog {
    try await request("probe", ["provider": provider.rawValue])
  }

  static func conversation() async throws -> ResearchSnapshot {
    try await request("conversation")
  }

  static func stop(thread: UUID, turn: UUID) async throws {
    let _: Empty = try await request("stop", ["threadId": thread.uuidString, "turnId": turn.uuidString])
  }

  static func stream(_ turn: ResearchTurn, asset: Asset, telegram: TelegramSession,
    event: @MainActor (ResearchEvent) -> Void) async throws {
    let base = try await LocalDataService.shared.readyURL()
    var request = URLRequest(url: base.appendingPathComponent("api/research/turn"), timeoutInterval: 220)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(turn)
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      var body = Data()
      for try await byte in bytes {
        guard body.count < 4096 else { break }
        body.append(byte)
      }
      throw LocalBackendClient.RequestError(
        message: (try? JSONDecoder().decode(Failure.self, from: body).error) ?? "Couldn’t start research.")
    }
    let decoder = JSONDecoder()
    for try await line in bytes.lines where !line.isEmpty {
      try Task.checkCancellation()
      let update = try decoder.decode(ResearchEvent.self, from: Data(line.utf8))
      if update.type == "tool_request", let requestId = update.requestId, let identity = update.asset {
        let result = await ResearchTelegramTool.read(identity: identity, current: asset, session: telegram)
        try Task.checkCancellation()
        let reply = ResearchTelegramTool.Reply(threadId: turn.threadId, turnId: turn.turnId,
          requestId: requestId, result: result)
        _ = try await LocalBackendClient.post("api/research/tool-result", body: JSONEncoder().encode(reply))
        continue
      }
      event(update)
      if update.type == "done" || update.type == "error" { return }
    }
    throw LocalBackendClient.RequestError(message: "The connection to the local research service ended.")
  }

  private static func request<T: Decodable>(_ name: String, _ parameters: [String: String] = [:]) async throws -> T {
    let data = try await LocalBackendClient.post("api/research/\(name)", body: JSONEncoder().encode(parameters))
    return try JSONDecoder().decode(T.self, from: data)
  }
}
