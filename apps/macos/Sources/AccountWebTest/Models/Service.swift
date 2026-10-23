import Foundation

enum Service: String, CaseIterable, Identifiable {
  case pump = "Pump"
  case fomo = "Fomo"
  var id: String { rawValue }
  var url: URL { URL(string: self == .pump ? "https://pump.fun/" : "https://fomo.family/")! }
  // Fixed identifiers deliberately preserve each service's own website data across launches.
  var storeID: UUID {
    UUID(
      uuidString: self == .pump
        ? "4B6C6332-C8A3-45BD-A499-3F14EB769301"
        : "D86281DA-0809-42F5-A828-C0F0CBA4C902")!
  }
}
