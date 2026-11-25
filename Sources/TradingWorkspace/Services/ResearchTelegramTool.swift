import Foundation

@MainActor
enum ResearchTelegramTool {
  struct Excerpt: Encodable {
    let chat: String
    let topic: String?
    let author: String
    let text: String
    let sentAt: String
    let url: URL?
  }

  struct Result: Encodable {
    let status: String
    let asset: String
    let asOf: String
    var excerpts: [Excerpt] = []
    var partial = false
    var reason: String?
  }

  struct Reply: Encodable {
    let threadId: UUID
    let turnId: UUID
    let requestId: UUID
    let result: Result
  }

  static func read(identity: String, current: Asset, session: TelegramSession) async -> Result {
    let checkedAt = Date.now.formatted(.iso8601)
    func unavailable(_ reason: String) -> Result {
      Result(status: "unavailable", asset: identity, asOf: checkedAt, reason: reason)
    }
    guard session.isConnected else { return unavailable("Telegram is disconnected in tRig.") }
    let start = session.epoch
    do {
      let asset: Asset
      if identity == current.identity {
        asset = current
      } else {
        guard let separator = identity.lastIndex(of: ":") else { return unavailable("Invalid asset.") }
        let chain = String(identity[..<separator])
        let address = String(identity[identity.index(after: separator)...])
        guard Asset.validAddress(address, chain: chain) else { return unavailable("Invalid asset.") }
        asset = try await AssetDiscoveryClient().resolve(address, chain: chain)
      }
      let page = try await session.discussion(for: asset)
      let matches = page.chats.flatMap { chat in
        let titles = Dictionary(uniqueKeysWithValues: chat.topics.map { ($0.id, $0.title) })
        return chat.allExchanges.flatMap { exchange in
          ([exchange.share, exchange.parent].compactMap { $0 } + exchange.replies).map {
            (chat, exchange.topic.flatMap { titles[$0] }, $0)
          }
        }
      }.sorted { $0.2.date > $1.2.date }
      var seen = Set<TelegramQuote.ID>()
      var excerpts: [Excerpt] = []
      let candidates = matches.filter { !($0.2.prose.isEmpty) && seen.insert($0.2.id).inserted }.prefix(8)
      for (chat, topic, quote) in candidates {
        try Task.checkCancellation()
        let link = chat.supportsMessageLink ? try? await session.link(for: quote.id) : nil
        excerpts.append(Excerpt(chat: chat.title, topic: topic, author: quote.author,
          text: String(quote.prose.prefix(1200)), sentAt: quote.date.formatted(.iso8601), url: link))
      }
      guard session.isConnected, start == session.epoch else { return unavailable("Telegram connection changed.") }
      return Result(status: excerpts.isEmpty ? "no_matches" : "ok", asset: identity,
        asOf: checkedAt, excerpts: excerpts, partial: page.incomplete || page.nextOffset != nil)
    } catch {
      return unavailable("Couldn’t read the current Telegram discussion.")
    }
  }
}
