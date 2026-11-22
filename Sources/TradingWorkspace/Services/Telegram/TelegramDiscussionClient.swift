import Foundation

@MainActor
struct TelegramDiscussionClient {
  let transport: any TelegramRequesting

  func page(for asset: Asset, offset: String) async throws -> TelegramDiscussionPage {
    guard Asset.validAddress(asset.id, chain: asset.chainID) else {
      throw TelegramError.invalidResponse
    }
    return try await Search(transport: transport, asset: asset).load(offset: offset)
  }

  func context(for exchange: TelegramExchange, asset: Asset, includeSurrounding: Bool)
    async throws -> TelegramExchangeContext
  {
    try await Search(transport: transport, asset: asset)
      .context(for: exchange, includeSurrounding: includeSurrounding)
  }

  func messageLink(_ id: TelegramQuote.ID) async throws -> URL {
    let reply = try await transport.request(.getMessageLink, [
      "chat_id": .integer(id.chat), "message_id": .integer(id.message),
      "media_timestamp": .integer(0), "checklist_task_id": .integer(0),
      "poll_option_id": .string(""), "for_album": .bool(false), "in_message_thread": .bool(false),
    ])
    guard reply.type == "messageLink", let source = reply["link"].string,
      let url = URL(string: source), url.scheme == "https", url.host == "t.me",
      url.user == nil, url.password == nil, url.port == nil
    else { throw TelegramError.invalidResponse }
    return url
  }
}

private struct Message {
  let id: TelegramQuote.ID
  let topic: Int64?
  let date: Date
  let sender: TelegramJSON
  let sentByBusinessBot: Bool
  let replyTo: Int64?
  let text: String
  let links: [String]

  init?(_ raw: TelegramJSON) {
    guard raw.type == "message", let chat = raw["chat_id"].int, chat != 0,
      let message = raw["id"].int, message > 0, let seconds = raw["date"].int, seconds > 0,
      raw["can_be_saved"].bool == true, raw["is_channel_post"].bool != true,
      raw["self_destruct_type"].type == nil, !raw["auto_delete_in"].isPositive,
      raw["restriction_info"].type == nil, raw["ephemeral_content"].type == nil
    else { return nil }
    let content = raw["content"]
    let formatted = content.type == "messageText" ? content["text"] : content["caption"]
    guard let text = formatted["text"].string, !text.isEmpty, content["is_secret"].bool != true
    else { return nil }

    self.id = .init(chat: chat, message: message)
    let topic = raw["topic_id"]
    self.topic = topic.type == "messageTopicForum" ? topic["forum_topic_id"].int : nil
    self.date = Date(timeIntervalSince1970: Double(seconds))
    self.sender = raw["sender_id"]
    self.sentByBusinessBot = (raw["sender_business_bot_user_id"].int ?? 0) != 0
    let reply = raw["reply_to"]
    let replyChat = reply["chat_id"].int
    self.replyTo = reply.type == "messageReplyToMessage" && (replyChat == chat || replyChat == 0)
      ? reply["message_id"].int : nil
    self.text = text
    self.links = (formatted["entities"].array ?? []).compactMap { entity in
      let type = entity["type"]
      return type.type == "textEntityTypeTextUrl" ? type["url"].string : nil
    }
  }
}

private extension TelegramJSON {
  var isPositive: Bool {
    if case .number(let value) = self { return value > 0 }
    return (int ?? 0) > 0
  }
}

/// One bounded page from Telegram's own search index. Only directly linked
/// replies are surfaced as context. Nearby unrelated messages stay out.
@MainActor
private final class Search {
  let transport: any TelegramRequesting
  let asset: Asset
  let contract: NSRegularExpression
  var chats: [Int64: TelegramJSON] = [:]
  var missingChats: Set<Int64> = []
  private var users: [Int64: Account] = [:]
  private var missingUsers: Set<Int64> = []
  private var topicNames: [TopicKey: String] = [:]
  private var missingTopics: Set<TopicKey> = []
  var incomplete = false

  private struct TopicKey: Hashable {
    let chat: Int64
    let topic: Int64
  }

  private struct Account {
    let name: String
    let isBot: Bool
  }

  init(transport: any TelegramRequesting, asset: Asset) throws {
    self.transport = transport
    self.asset = asset
    let escaped = NSRegularExpression.escapedPattern(for: asset.id)
    contract = try NSRegularExpression(pattern: "(?<![A-Za-z0-9_])\(escaped)(?![A-Za-z0-9_])",
      options: asset.isSolana ? [] : .caseInsensitive)
  }

  func load(offset: String) async throws -> TelegramDiscussionPage {
    let response = try await transport.request(.searchMessages, [
      "chat_list": .null, "query": .string(asset.id), "offset": .string(offset),
      "limit": .integer(30), "filter": .null, "chat_type_filter": .null,
      "min_date": .integer(0), "max_date": .integer(0),
    ])
    guard response.type == "foundMessages", let rawMessages = response["messages"].array
    else { throw TelegramError.invalidResponse }
    let matches = rawMessages.compactMap(Message.init).filter(matchesAsset)
    var matchesByID: [TelegramQuote.ID: Message] = [:]
    for match in matches { matchesByID[match.id] = match }
    var seen = Set<TelegramQuote.ID>()
    var sources: [Int64: [Int64?: [TelegramExchange]]] = [:]
    var contextRequests = 0
    var parentLookups = 0
    for match in matches where !seen.contains(match.id) {
      try Task.checkCancellation()
      guard let chat = try await eligibleChat(match.id.chat) else { continue }
      var anchor = match
      var share = try await quote(match, chat: chat)
      if share == nil, let parentID = match.replyTo {
        let key = TelegramQuote.ID(chat: match.id.chat, message: parentID)
        let parent: Message?
        if let known = matchesByID[key] {
          parent = known
        } else if parentLookups < 6 {
          // Telegram search can return an automated reply before it returns
          // the human post the reply quotes. Resolve that post if in scope.
          parentLookups += 1
          do { parent = try await message(key) }
          catch is CancellationError { throw CancellationError() }
          catch { parent = nil }
        } else {
          parent = nil
        }
        if let parent, parent.id == key, parent.topic == match.topic, matchesAsset(parent),
          let original = try await quote(parent, chat: chat) {
          anchor = parent
          share = original
        }
      }
      guard seen.insert(anchor.id).inserted else { continue }
      var context: TelegramExchangeContext?
      if contextRequests < 6 {
        contextRequests += 1
        do {
          context = try await loadContext(anchor, chat: chat, includeSurrounding: false,
            previewNearby: share?.prose.isEmpty != false)
        }
        catch is CancellationError { throw CancellationError() }
        catch { incomplete = true }
      }
      let replies = context?.replies ?? []
      guard share != nil || !replies.isEmpty else { continue }
      let exchange = TelegramExchange(id: anchor.id, topic: anchor.topic, date: anchor.date,
        share: share, parent: context?.parent, replies: replies,
        nearbyBefore: context?.before.last, nearbyAfter: context?.after.first,
        repliesLoaded: context != nil,
        chainUnconfirmed: !asset.isSolana && !confirmsChain(anchor))
      sources[anchor.id.chat, default: [:]][anchor.topic, default: []].append(exchange)
    }

    var groups: [TelegramDiscussionChat] = []
    for (id, buckets) in sources {
      guard let chat = chats[id], let kind = kind(chat) else { continue }
      var unthreaded = buckets[nil] ?? []
      var topics: [TelegramDiscussionTopic] = []
      for (topic, exchanges) in buckets {
        guard let topic else { continue }
        if kind == .group, let title = try await topicTitle(chat: id, topic: topic) {
          topics.append(.init(id: topic, title: title, exchanges: exchanges.sorted(by: TelegramExchange.newer)))
        } else {
          unthreaded += exchanges
        }
      }
      groups.append(.init(id: id, title: chat["title"].string ?? "Conversation", kind: kind,
        supportsMessageLink: chat["type"].type == "chatTypeSupergroup",
        exchanges: unthreaded.sorted(by: TelegramExchange.newer),
        topics: topics.sorted(by: TelegramDiscussionPage.newer)))
    }
    let next = response["next_offset"].string.flatMap { $0.isEmpty || $0 == offset ? nil : $0 }
    return .init(chats: groups.sorted(by: TelegramDiscussionPage.newer),
      nextOffset: next, incomplete: incomplete)
  }

  private func chat(_ id: Int64) async throws -> TelegramJSON? {
    if let found = chats[id] { return found }
    guard !missingChats.contains(id) else { return nil }
    do {
      let result = try await transport.request(.getChat, ["chat_id": .integer(id)])
      guard result.type == "chat", result["id"].int == id else { throw TelegramError.invalidResponse }
      chats[id] = result
      return result
    } catch is CancellationError { throw CancellationError() }
    catch {
      incomplete = true
      missingChats.insert(id)
      return nil
    }
  }

  private func kind(_ chat: TelegramJSON) -> TelegramChatKind? {
    guard chat["has_protected_content"].bool != true else { return nil }
    switch chat["type"].type {
    case "chatTypePrivate": return .directMessage
    case "chatTypeBasicGroup": return .group
    case "chatTypeSupergroup":
      return chat["type"]["is_channel"].bool == false ? .group : nil
    default: return nil
    }
  }

  private func eligibleChat(_ id: Int64) async throws -> TelegramJSON? {
    guard let chat = try await chat(id), let kind = kind(chat) else { return nil }
    if kind == .directMessage {
      // Outgoing messages in a bot DM have a human author. Check the peer.
      guard let peer = chat["type"]["user_id"].int else {
        incomplete = true
        return nil
      }
      guard let account = try await account(peer), !account.isBot else { return nil }
    }
    return chat
  }

  func context(for exchange: TelegramExchange, includeSurrounding: Bool)
    async throws -> TelegramExchangeContext
  {
    guard let chat = try await eligibleChat(exchange.id.chat) else {
      throw TelegramError.invalidResponse
    }
    guard let anchor = try await message(exchange.id), anchor.id == exchange.id,
      anchor.topic == exchange.topic, matchesAsset(anchor) else {
      throw TelegramError.invalidResponse
    }
    return try await loadContext(anchor, chat: chat, includeSurrounding: includeSurrounding,
      previewNearby: exchange.share?.prose.isEmpty != false)
  }

  private func message(_ id: TelegramQuote.ID) async throws -> Message? {
    Message(try await transport.request(.getMessage, [
      "chat_id": .integer(id.chat), "message_id": .integer(id.message),
    ]))
  }

  private func loadContext(_ anchor: Message, chat: TelegramJSON, includeSurrounding: Bool,
    previewNearby: Bool)
    async throws -> TelegramExchangeContext
  {
    var fields: [String: TelegramJSON] = [
      "chat_id": .integer(anchor.id.chat), "from_message_id": .integer(anchor.id.message),
      "offset": .integer(-10), "limit": .integer(20),
    ]
    let method: TelegramMethod
    if let topic = anchor.topic {
      method = .getForumTopicHistory
      fields["forum_topic_id"] = .integer(topic)
    } else {
      method = .getChatHistory
      fields["only_local"] = .bool(false)
    }
    let response = try await transport.request(method, fields)
    guard response.type == "messages", let raw = response["messages"].array
    else { throw TelegramError.invalidResponse }
    var seen: Set<TelegramQuote.ID> = [anchor.id]
    let messages = raw.compactMap(Message.init).filter {
      $0.id.chat == anchor.id.chat && $0.topic == anchor.topic && seen.insert($0.id).inserted
    }

    var parent: TelegramQuote?
    if let parentID = anchor.replyTo {
      do {
        let parentMessage: Message?
        if let nearby = messages.first(where: { $0.id.message == parentID }) {
          parentMessage = nearby
        } else {
          parentMessage = try await message(.init(chat: anchor.id.chat, message: parentID))
        }
        if let message = parentMessage, message.id.chat == anchor.id.chat,
          message.id.message == parentID, message.topic == anchor.topic {
          parent = try await quote(message, chat: chat)
        }
      } catch is CancellationError { throw CancellationError() }
      catch { incomplete = true }
    }

    let linked = messages.filter { $0.replyTo == anchor.id.message }
      .sorted { $0.id.message < $1.id.message }
    let replies = try await quotes(linked, chat: chat, limit: 6)
    guard includeSurrounding || previewNearby else {
      return .init(parent: parent, replies: replies, before: [], after: [])
    }

    let context = messages.filter {
      $0.id.message != anchor.replyTo && $0.replyTo != anchor.id.message
    }
    let limit = includeSurrounding ? 3 : 1
    let before = try await quotes(context.filter { $0.id.message < anchor.id.message }
      .sorted { $0.id.message > $1.id.message }, chat: chat, limit: limit, requiresProse: !includeSurrounding)
    let after = try await quotes(context.filter { $0.id.message > anchor.id.message }
      .sorted { $0.id.message < $1.id.message }, chat: chat, limit: limit, requiresProse: !includeSurrounding)
    return .init(parent: parent, replies: replies.sorted(by: TelegramQuote.chronological),
      before: before.sorted(by: TelegramQuote.chronological),
      after: after.sorted(by: TelegramQuote.chronological))
  }

  private func quotes(_ messages: [Message], chat: TelegramJSON, limit: Int,
    requiresProse: Bool = false) async throws -> [TelegramQuote]
  {
    var results: [TelegramQuote] = []
    for message in messages {
      try Task.checkCancellation()
      if let quote = try await quote(message, chat: chat), !requiresProse || quote.hasPreviewText {
        results.append(quote)
      }
      if results.count == limit { break }
    }
    return results
  }

  private func quote(_ message: Message, chat: TelegramJSON) async throws -> TelegramQuote? {
    guard !message.sentByBusinessBot, let author = try await author(message.sender, chat: chat)
    else { return nil }
    let parts = excerpt(message)
    guard !parts.isEmpty else { return nil }
    return TelegramQuote(id: message.id, author: author, date: message.date, parts: parts)
  }

  private func matchesAsset(_ message: Message) -> Bool {
    matchesContract(message.text) || message.links.contains(where: matchesContract)
  }

  private func topicTitle(chat: Int64, topic: Int64) async throws -> String? {
    let key = TopicKey(chat: chat, topic: topic)
    if let found = topicNames[key] { return found }
    guard !missingTopics.contains(key) else { return nil }
    do {
      let response = try await transport.request(.getForumTopic,
        ["chat_id": .integer(chat), "forum_topic_id": .integer(topic)])
      let info = response["info"]
      guard response.type == "forumTopic", info["chat_id"].int == chat,
        info["forum_topic_id"].int == topic, let name = info["name"].string, !name.isEmpty
      else { throw TelegramError.invalidResponse }
      topicNames[key] = name
      return name
    } catch is CancellationError { throw CancellationError() }
    catch {
      incomplete = true
      missingTopics.insert(key)
      return nil
    }
  }

  private func account(_ id: Int64) async throws -> Account? {
    if let found = users[id] { return found }
    guard !missingUsers.contains(id) else { return nil }
    do {
      let value = try await transport.request(.getUser, ["user_id": .integer(id)])
      let type = value["type"].type
      guard value.type == "user", value["id"].int == id,
        type == "userTypeRegular" || type == "userTypeBot"
      else { throw TelegramError.invalidResponse }
      let names = [value["first_name"].string, value["last_name"].string]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
      let account = Account(name: names.isEmpty ? "Unknown sender" : names, isBot: type == "userTypeBot")
      users[id] = account
      return account
    } catch is CancellationError { throw CancellationError() }
    catch {
      incomplete = true
      missingUsers.insert(id)
      return nil
    }
  }

  private func author(_ sender: TelegramJSON, chat source: TelegramJSON) async throws -> String? {
    switch sender.type {
    case "messageSenderUser":
      guard let id = sender["user_id"].int, let account = try await account(id),
        !account.isBot else { return nil }
      return account.name
    case "messageSenderChat":
      guard let id = sender["chat_id"].int else { return "Unknown sender" }
      if id == source["id"].int { return source["title"].string ?? "Group" }
      return try await chat(id)?["title"].string ?? "Unknown sender"
    default: return "Unknown sender"
    }
  }

  private func matchesContract(_ text: String) -> Bool {
    contract.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  private func confirmsChain(_ anchor: Message) -> Bool {
    guard let explorerHost = asset.explorer?.host?.lowercased() else { return false }
    let plainLinks = anchor.text.split(whereSeparator: \.isWhitespace).map(String.init)
    return (anchor.links + plainLinks).contains {
      guard let url = URL(string: $0), url.scheme == "https",
        url.host?.lowercased() == explorerHost, url.user == nil, url.password == nil else { return false }
      return url.pathComponents.contains { $0.lowercased() == asset.id.lowercased() }
    }
  }

  private func excerpt(_ message: Message) -> [TelegramQuotePart] {
    let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let range = NSRange(text.startIndex..., in: text)
    // Substitute the whole URL when the exact CA is inside it. A naked address
    // inside prose becomes a chip at its original position.
    let urlRanges = Self.urls.matches(in: text, range: range).filter {
      matchesContract((text as NSString).substring(with: $0.range))
    }.map(\.range)
    let rawRanges = contract.matches(in: text, range: range).map(\.range).filter { match in
      !urlRanges.contains { NSIntersectionRange($0, match).length > 0 }
    }
    let replacements = (urlRanges + rawRanges).sorted { $0.location < $1.location }
    var parts: [TelegramQuotePart] = []
    var start = text.startIndex
    var remaining = 360

    func appendText(_ value: Substring) {
      guard remaining > 0, !value.isEmpty else { return }
      let prefix = value.prefix(remaining)
      let truncated = prefix.endIndex != value.endIndex
      parts.append(.text(String(prefix) + (truncated ? "…" : "")))
      remaining -= prefix.count
    }

    for replacement in replacements {
      guard let range = Range(replacement, in: text) else { continue }
      appendText(text[start..<range.lowerBound])
      if remaining > 0 {
        parts.append(.cashtag)
        remaining -= 1
      }
      start = range.upperBound
    }
    appendText(text[start...])
    if !parts.contains(.cashtag), !replacements.isEmpty || message.links.contains(where: matchesContract) {
      // Telegram may store a contract URL under a human-written link label.
      if !parts.isEmpty { parts.append(.text(" ")) }
      parts.append(.cashtag)
    }
    return parts
  }

  private static let urls = try! NSRegularExpression(pattern: "https?://[^\\s<>]+",
    options: .caseInsensitive)
}
