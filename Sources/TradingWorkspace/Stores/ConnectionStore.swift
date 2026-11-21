import Observation

@MainActor @Observable
final class ConnectionStore {
  @ObservationIgnored var onDisconnect: (@MainActor (ConnectionService) async throws -> Void)?
  @ObservationIgnored private var restoration: Task<Void, Never>?
  let fomo = ConnectionBrowserSession(service: .fomo)
  let pump = ConnectionBrowserSession(service: .pump)
  init() {
    fomo.onDisconnect = { [weak self] in try await self?.onDisconnect?(.fomo) }
    pump.onDisconnect = { [weak self] in try await self?.onDisconnect?(.pump) }
  }
  func session(for service: ConnectionService) -> ConnectionBrowserSession {
    service == .fomo ? fomo : pump
  }
  var accountSignature: String {
    ConnectionService.allCases.map { service in
      service.rawValue + ":" + (session(for: service).profile?.wallet ?? "disconnected")
    }.joined(separator: "|")
  }
  func restore() async {
    if let restoration {
      await restoration.value
      return
    }
    let task = Task {
      async let fomoRestore: Void = fomo.restore()
      async let pumpRestore: Void = pump.restore()
      _ = await (fomoRestore, pumpRestore)
    }
    restoration = task
    await task.value
    restoration = nil
  }
}
