import Foundation

enum ConnectionService: String, CaseIterable, Identifiable, Codable, Sendable {
  case fomo
  case pump
  var id: Self { self }
  var name: String { self == .fomo ? "Fomo" : "Pumpfun" }
  var homeURL: URL { URL(string: self == .fomo ? "https://fomo.family/" : "https://pump.fun/")! }

  func profileURL(for profile: ConnectedProfile) -> URL? {
    let account: String
    switch self {
    case .fomo:
      guard let username = profile.username,
        username != ".", username != "..",
        username.range(of: #"\A[A-Za-z0-9_.]+\z"#, options: .regularExpression) != nil
      else { return nil }
      account = username
    case .pump:
      guard ConnectionProfileRules.isWallet(profile.wallet), !profile.wallet.hasPrefix("0x")
      else { return nil }
      account = profile.wallet
    }
    return homeURL.appendingPathComponent("profile").appendingPathComponent(account)
  }

  var storeID: UUID {
    UUID(
      uuidString: self == .fomo
        ? "D86281DA-0809-42F5-A828-C0F0CBA4C902"
        : "4B6C6332-C8A3-45BD-A499-3F14EB769301")!
  }
}

struct ConnectedProfile: Equatable, Sendable {
  let username: String?
  let wallet: String
  let checkedAt: Date
}

struct ConnectionFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
