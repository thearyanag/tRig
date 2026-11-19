import Foundation
import Observation

@MainActor @Observable
final class ChartStatus {
  var phase = "loading"
  var message = "Starting chart…"
  var lastClose: Double?
  var fetchedAt: Date?

  func receive(_ body: Any) {
    guard let value = body as? [String: Any],
      let phase = value["phase"] as? String,
      let message = value["message"] as? String
    else { return }
    self.phase = phase
    self.message = message
    if let price = value["lastClose"] as? Double, price.isFinite, price > 0 { lastClose = price }
    if let fetched = value["fetchedAt"] as? Double {
      fetchedAt = Date(timeIntervalSince1970: fetched)
    }
  }
}
