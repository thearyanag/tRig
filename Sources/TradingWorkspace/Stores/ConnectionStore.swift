import Observation

@MainActor @Observable
final class ConnectionStore {
  let fomo = ConnectionBrowserSession(service: .fomo)
  let pump = ConnectionBrowserSession(service: .pump)
  func session(for service: ConnectionService) -> ConnectionBrowserSession {
    service == .fomo ? fomo : pump
  }
  func restore() async {
    async let fomoRestore: Void = fomo.restore()
    async let pumpRestore: Void = pump.restore()
    _ = await (fomoRestore, pumpRestore)
  }
}
