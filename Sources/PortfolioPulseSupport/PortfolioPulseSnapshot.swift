import Foundation

public struct PortfolioPulseSnapshot: Codable, Equatable, Sendable {
  public static let kind = "PortfolioPulse"
  public static let portfolioURL = URL(string: "trig://portfolio")!

  public struct Contributor: Codable, Equatable, Sendable {
    public let symbol: String
    public let amount: Decimal
    public let icon: String?

    public init(symbol: String, amount: Decimal, icon: String? = nil) {
      self.symbol = symbol
      self.amount = amount
      self.icon = icon
    }
  }

  public struct Point: Codable, Equatable, Sendable {
    public let date: Date
    public let value: Double

    public init(date: Date, value: Double) {
      self.date = date
      self.value = value
    }
  }

  public let sources: String
  public let balance: Decimal
  public let move: Decimal?
  public let movePercent: Decimal?
  public let history: [[Point]]
  public let contributor: Contributor?
  public let updatedAt: Date

  public init(
    sources: String, balance: Decimal, move: Decimal?, movePercent: Decimal?,
    history: [[Point]], contributor: Contributor?, updatedAt: Date
  ) {
    self.sources = sources
    self.balance = balance
    self.move = move
    self.movePercent = movePercent
    self.history = history
    self.contributor = contributor
    self.updatedAt = updatedAt
  }
}

public struct PortfolioPulseStorage {
  public static func shared() -> Self? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "TRIGPortfolioAppGroup") as? String,
      let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    else { return nil }
    return Self(url: directory.appendingPathComponent("portfolio-pulse-v1.json"))
  }

  public let url: URL
  public init(url: URL) { self.url = url }

  public func read() -> PortfolioPulseSnapshot? {
    guard let data = try? Data(contentsOf: url), data.count <= 64 * 1024 else { return nil }
    return try? JSONDecoder().decode(PortfolioPulseSnapshot.self, from: data)
  }

  @discardableResult
  public func write(_ snapshot: PortfolioPulseSnapshot?) throws -> Bool {
    if let snapshot {
      guard snapshot != read() else { return false }
      try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
      return true
    }
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    try FileManager.default.removeItem(at: url)
    return true
  }
}
