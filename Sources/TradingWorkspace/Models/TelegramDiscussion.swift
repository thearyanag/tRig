import Foundation

enum TelegramChatKind: String, Sendable {
  case group = "Group"
  case directMessage = "Direct message"
}

enum TelegramQuotePart: Equatable, Sendable {
  case text(String)
  case cashtag
}

struct TelegramQuote: Identifiable, Equatable, Sendable {
  struct ID: Hashable, Sendable {
    let chat: Int64
    let message: Int64
  }

  let id: ID
  let author: String
  let date: Date
  let parts: [TelegramQuotePart]

  var prose: String {
    parts.compactMap { part in if case .text(let text) = part { text } else { nil } }
      .joined().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var hasPreviewText: Bool {
    prose.split(whereSeparator: \.isWhitespace).contains { word in
      let text = String(word).trimmingCharacters(in: .punctuationCharacters)
      guard text.contains(where: \.isLetter),
        !Asset.validAddress(text, chain: "solana"), !Asset.validAddress(text, chain: "eip155:1")
      else { return false }
      let scheme = URL(string: text)?.scheme?.lowercased()
      return scheme != "https" && scheme != "http"
    }
  }

  static func chronological(_ lhs: Self, _ rhs: Self) -> Bool {
    lhs.date == rhs.date ? lhs.id.message < rhs.id.message : lhs.date < rhs.date
  }
}

struct TelegramExchange: Identifiable, Equatable, Sendable {
  let id: TelegramQuote.ID
  let topic: Int64?
  let date: Date
  let share: TelegramQuote?
  let parent: TelegramQuote?
  let replies: [TelegramQuote]
  let nearbyBefore: TelegramQuote?
  let nearbyAfter: TelegramQuote?
  let repliesLoaded: Bool
  let chainUnconfirmed: Bool

  var preview: TelegramQuote? { share ?? replies.first ?? parent }
  var latest: Date { max(date, replies.last?.date ?? date) }
  var displayedIDs: Set<TelegramQuote.ID> {
    Set([id] + [parent?.id, nearbyBefore?.id, nearbyAfter?.id].compactMap { $0 } + replies.map(\.id))
  }

  func excluding(_ changes: Set<TelegramQuote.ID>) -> Self? {
    guard !changes.contains(id) else { return nil }
    let parent = parent.flatMap { changes.contains($0.id) ? nil : $0 }
    let replies = replies.filter { !changes.contains($0.id) }
    guard share != nil || parent != nil || !replies.isEmpty else { return nil }
    return Self(id: id, topic: topic, date: date, share: share, parent: parent, replies: replies,
      nearbyBefore: nearbyBefore.flatMap { changes.contains($0.id) ? nil : $0 },
      nearbyAfter: nearbyAfter.flatMap { changes.contains($0.id) ? nil : $0 },
      repliesLoaded: repliesLoaded, chainUnconfirmed: chainUnconfirmed)
  }

  static func newer(_ lhs: Self, _ rhs: Self) -> Bool {
    lhs.latest == rhs.latest ? lhs.id.message > rhs.id.message : lhs.latest > rhs.latest
  }
}

struct TelegramExchangeContext: Equatable, Sendable {
  let parent: TelegramQuote?
  let replies: [TelegramQuote]
  let before: [TelegramQuote]
  let after: [TelegramQuote]

  var quotes: [TelegramQuote] { [parent].compactMap { $0 } + replies + before + after }
}

struct TelegramDiscussionTopic: Identifiable, Equatable, Sendable {
  let id: Int64
  let title: String
  let exchanges: [TelegramExchange]

  var latest: TelegramExchange? { exchanges.first }
}

struct TelegramDiscussionChat: Identifiable, Equatable, Sendable {
  let id: Int64
  let title: String
  let kind: TelegramChatKind
  let supportsMessageLink: Bool
  let exchanges: [TelegramExchange]
  let topics: [TelegramDiscussionTopic]

  var allExchanges: [TelegramExchange] { exchanges + topics.flatMap(\.exchanges) }
  var latest: TelegramExchange? { allExchanges.min(by: TelegramExchange.newer) }
}

struct TelegramDiscussionPage: Sendable {
  let chats: [TelegramDiscussionChat]
  let nextOffset: String?
  let incomplete: Bool

  func merging(_ next: Self) -> Self {
    var sources: [Int64: TelegramDiscussionChat] = [:]
    for chat in chats + next.chats {
      guard let previous = sources[chat.id] else { sources[chat.id] = chat; continue }
      var topics: [Int64: TelegramDiscussionTopic] = [:]
      for topic in previous.topics + chat.topics {
        topics[topic.id] = TelegramDiscussionTopic(id: topic.id, title: topic.title,
          exchanges: Self.unique((topics[topic.id]?.exchanges ?? []) + topic.exchanges))
      }
      let all = Self.unique(previous.allExchanges + chat.allExchanges)
      let unthreaded = all.filter { item in item.topic.map { topics[$0] == nil } ?? true }
      let threaded = topics.values.map { topic in
        TelegramDiscussionTopic(id: topic.id, title: topic.title,
          exchanges: all.filter { $0.topic == topic.id })
      }.filter { !$0.exchanges.isEmpty }
      sources[chat.id] = TelegramDiscussionChat(id: chat.id, title: chat.title, kind: chat.kind,
        supportsMessageLink: chat.supportsMessageLink, exchanges: unthreaded,
        topics: threaded.sorted(by: Self.newer))
    }
    return Self(chats: sources.values.sorted(by: Self.newer), nextOffset: next.nextOffset,
      incomplete: incomplete || next.incomplete)
  }

  func removingChangedMessages(_ changed: Set<TelegramQuote.ID>) -> Self {
    let filtered = chats.compactMap { chat -> TelegramDiscussionChat? in
      let exchanges = chat.exchanges.compactMap { $0.excluding(changed) }
      let topics = chat.topics.compactMap { topic -> TelegramDiscussionTopic? in
        let exchanges = topic.exchanges.compactMap { $0.excluding(changed) }
        return exchanges.isEmpty ? nil : TelegramDiscussionTopic(id: topic.id, title: topic.title,
          exchanges: exchanges.sorted(by: TelegramExchange.newer))
      }
      guard !exchanges.isEmpty || !topics.isEmpty else { return nil }
      return TelegramDiscussionChat(id: chat.id, title: chat.title, kind: chat.kind,
        supportsMessageLink: chat.supportsMessageLink,
        exchanges: exchanges.sorted(by: TelegramExchange.newer), topics: topics.sorted(by: Self.newer))
    }
    return Self(chats: filtered.sorted(by: Self.newer), nextOffset: nextOffset,
      incomplete: incomplete || filtered != chats)
  }

  private static func unique(_ exchanges: [TelegramExchange]) -> [TelegramExchange] {
    var byID: [TelegramQuote.ID: TelegramExchange] = [:]
    for exchange in exchanges {
      // An older page can repeat a share after its reply lookup budget is exhausted.
      if byID[exchange.id]?.repliesLoaded == true, !exchange.repliesLoaded { continue }
      byID[exchange.id] = exchange
    }
    return byID.values.sorted(by: TelegramExchange.newer)
  }

  static func newer(_ lhs: TelegramDiscussionChat, _ rhs: TelegramDiscussionChat) -> Bool {
    let a = lhs.latest?.latest ?? .distantPast, b = rhs.latest?.latest ?? .distantPast
    return a == b ? lhs.id < rhs.id : a > b
  }

  static func newer(_ lhs: TelegramDiscussionTopic, _ rhs: TelegramDiscussionTopic) -> Bool {
    let a = lhs.latest?.latest ?? .distantPast, b = rhs.latest?.latest ?? .distantPast
    return a == b ? lhs.id < rhs.id : a > b
  }
}
