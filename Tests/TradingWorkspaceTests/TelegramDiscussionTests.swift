import Foundation
import Testing
@testable import TradingWorkspace

@MainActor
private final class DiscussionTransportFixture: TelegramRequesting {
  typealias JSON = TelegramJSON
  var matches: [JSON] = []
  var nearby: [Int64: [JSON]] = [:]
  var sources: [Int64: JSON] = [:]
  var messagesByID: [Int64: JSON] = [:]
  var bots: Set<Int64> = []
  var unknownUsers: Set<Int64> = []
  var offset = ""
  var calls: [(TelegramMethod, [String: JSON])] = []
  var returnedLink = "https://t.me/c/123/456"

  func request(_ method: TelegramMethod, _ fields: [String: JSON]) async throws -> JSON {
    calls.append((method, fields))
    switch method {
    case .searchMessages:
      return .object("foundMessages", ["messages": .array(matches), "next_offset": .string(offset)])
    case .getChat:
      return sources[fields["chat_id"]?.int ?? 0] ?? .null
    case .getUser:
      let id = fields["user_id"]?.int ?? 0
      let type = unknownUsers.contains(id) ? "userTypeUnknown"
        : bots.contains(id) ? "userTypeBot" : "userTypeRegular"
      return .object("user", [
        "id": .integer(id), "first_name": .string(id == 11 ? "Maya" : "Ravi"),
        "type": .object(type),
      ])
    case .getMessage:
      let id = fields["message_id"]?.int ?? 0
      return messagesByID[id] ?? matches.first { $0["id"].int == id } ?? .null
    case .getChatHistory, .getForumTopicHistory:
      return .object("messages", ["messages": .array(nearby[fields["from_message_id"]?.int ?? 0] ?? [])])
    case .getForumTopic:
      let chat = fields["chat_id"] ?? .null
      let topic = fields["forum_topic_id"] ?? .null
      return .object("forumTopic", ["info": .object("forumTopicInfo", [
        "chat_id": chat, "forum_topic_id": topic,
        "name": .string(topic.int == 7 ? "Liquidity" : "Tokenomics"),
      ])])
    case .getMessageLink: return .object("messageLink", ["link": .string(returnedLink)])
    default: return .null
    }
  }

  func source(_ id: Int64, _ title: String, type: String, channel: Bool = false, peer: Int64? = nil) {
    sources[id] = .object("chat", [
      "id": .integer(id), "title": .string(title),
      "type": .object(type, type == "chatTypePrivate"
        ? ["user_id": .integer(peer ?? id)] : ["is_channel": .bool(channel)]),
    ])
  }

  func message(
    _ id: Int64, chat: Int64, sender: Int64 = 11, _ text: String, topic: Int64? = nil,
    reply: Int64? = nil, replyChat: Int64? = nil, canBeSaved: Bool = true,
    businessBot: Int64? = nil, link: String? = nil
  ) -> JSON {
    .object("message", [
      "id": .integer(id), "chat_id": .integer(chat), "date": .integer(1_790_000_000 + id),
      "sender_id": .object("messageSenderUser", ["user_id": .integer(sender)]),
      "can_be_saved": .bool(canBeSaved),
      "sender_business_bot_user_id": .integer(businessBot ?? 0),
      "topic_id": topic.map { .object("messageTopicForum", ["forum_topic_id": .integer($0)]) } ?? .null,
      "reply_to": reply.map { .object("messageReplyToMessage", [
        "message_id": .integer($0), "chat_id": .integer(replyChat ?? chat),
      ]) } ?? .null,
      "content": .object("messageText", ["text": .object("formattedText", [
        "text": .string(text),
        "entities": .array(link.map { [.object("textEntity", ["type": .object(
          "textEntityTypeTextUrl", ["url": .string($0)])])] } ?? []),
      ])]),
    ])
  }
}

@Test @MainActor func telegramHidesBotDMsAndGroupBotQuotesButKeepsHumanDiscussion() async throws {
  let asset = Asset.backpack
  let mock = DiscussionTransportFixture()
  mock.bots = [400]
  mock.unknownUsers = [401]
  mock.source(100, "Market Scanner", type: "chatTypePrivate", peer: 400)
  mock.source(101, "Unclassified account", type: "chatTypePrivate", peer: 401)
  mock.source(102, "Maya", type: "chatTypePrivate", peer: 11)
  mock.source(-100, "Solana Market Desk", type: "chatTypeSupergroup")
  mock.matches = [
    mock.message(92, chat: 100, "Human command to bot \(asset.id)"),
    mock.message(91, chat: 100, sender: 400, "Scanner response \(asset.id)"),
    mock.message(90, chat: 101, "Unverified peer \(asset.id)"),
    mock.message(89, chat: 102, sender: 12, "Human DM \(asset.id)"),
    mock.message(80, chat: -100, asset.id),
    mock.message(75, chat: -100, sender: 400, "Automated alert \(asset.id)"),
    mock.message(70, chat: -100, "Business bot message \(asset.id)", businessBot: 400),
  ]
  mock.nearby[80] = [mock.message(81, chat: -100, sender: 400, "Bot reply", reply: 80)]
  mock.nearby[75] = [mock.message(78, chat: -100, "Human reply to the alert", reply: 75)]

  let page = try await TelegramDiscussionClient(transport: mock).page(for: asset, offset: "")

  #expect(page.chats.map(\.id) == [102, -100])
  #expect(page.chats.first?.exchanges.first?.share?.prose == "Human DM")
  let group = try #require(page.chats.last)
  #expect(group.exchanges.first?.share?.parts == [.cashtag])
  #expect(group.exchanges.first?.replies.isEmpty == true)
  #expect(group.exchanges.last?.share == nil)
  #expect(group.exchanges.last?.replies.map(\.prose) == ["Human reply to the alert"])
  #expect(page.incomplete)
  #expect(!mock.calls.contains {
    $0.0 == .getChatHistory && [100, 101].contains($0.1["chat_id"]?.int ?? 0)
  })
  #expect(mock.calls.filter { $0.0 == .getUser && $0.1["user_id"]?.int == 400 }.count == 1)
}

@Test @MainActor func telegramGroupsTopicsAndDirectMessagesWithOnlyLinkedContext() async throws {
  let asset = Asset.backpack
  let mock = DiscussionTransportFixture()
  mock.source(-100, "Solana Market Desk", type: "chatTypeSupergroup")
  mock.source(-200, "Builders Room", type: "chatTypeBasicGroup")
  mock.source(11, "Maya", type: "chatTypePrivate")
  mock.source(-300, "Broadcast", type: "chatTypeSupergroup", channel: true)

  let liquidity = mock.message(100, chat: -100, asset.id, topic: 7)
  mock.matches = [
    liquidity, liquidity,
    mock.message(90, chat: -100, sender: 12, "Waiting for the unlock. \(asset.id)", topic: 8),
    mock.message(80, chat: -200, asset.id),
    mock.message(70, chat: 11, "Added BP. \(asset.id)"),
    mock.message(65, chat: -100, "Do not surface \(asset.id)", topic: 7, canBeSaved: false),
    mock.message(60, chat: -100, "Case mismatch \(asset.id.lowercased())", topic: 7),
    mock.message(55, chat: -100, "Partial mint \(asset.id)9", topic: 7),
    mock.message(50, chat: -300, "Channel post \(asset.id)"),
  ]
  mock.nearby[100] = [
    mock.message(104, chat: -100, "The bid is still thin.", topic: 7, reply: 100),
    mock.message(103, chat: -100, "Cross-chat reply", topic: 7, reply: 100, replyChat: -200),
    mock.message(102, chat: -100, "Another topic", topic: 8, reply: 100),
    mock.message(101, chat: -100, "Unrelated nearby message", topic: 7),
  ]
  mock.offset = "next"

  let result = try await TelegramDiscussionClient(transport: mock).page(for: asset, offset: "")
  #expect(result.nextOffset == "next")
  #expect(result.chats.map(\.title) == ["Solana Market Desk", "Builders Room", "Maya"])
  #expect(result.chats.map(\.kind) == [.group, .group, .directMessage])
  let desk = try #require(result.chats.first)
  #expect(desk.topics.map(\.title) == ["Liquidity", "Tokenomics"])
  let exchange = try #require(desk.topics.first?.exchanges.first)
  #expect(exchange.share?.parts == [.cashtag])
  #expect(exchange.replies.map(\.prose) == ["The bid is still thin."])
  #expect(exchange.replies.first?.author == "Maya")
  #expect(desk.topics.last?.exchanges.first?.share?.parts == [.text("Waiting for the unlock. "), .cashtag])
  #expect(result.chats[1].exchanges.first?.share?.parts == [.cashtag])
  #expect(result.chats[2].exchanges.first?.share?.prose == "Added BP.")
  #expect(result.chats[2].topics.isEmpty)
  #expect(mock.calls.first?.1["chat_list"]?.type == nil)
  #expect(mock.calls.first?.1["query"]?.string == asset.id)
  #expect(mock.calls.filter { $0.0 == .getChatHistory || $0.0 == .getForumTopicHistory }.count == 4)
}

@Test @MainActor func telegramSearchUsesExactEVMAddressAndLabelsUnconfirmedChains() async throws {
  let asset = Asset(id: "0xabcdef1234567890abcdef1234567890abcdef12", name: "Asset",
    symbol: "TEST", network: "Base", pool: "", decimals: 18, priceUsd: nil,
    chainId: "eip155:8453", explorerUrl: "https://basescan.org")
  let mock = DiscussionTransportFixture()
  mock.source(-100, "Solana Market Desk", type: "chatTypeSupergroup")
  mock.matches = [
    mock.message(50, chat: -100, "My note \(asset.id.uppercased())"),
    mock.message(40, chat: -100, "Base discussion https://basescan.org/token/\(asset.id)"),
    mock.message(30, chat: -100, "Another contract \(asset.id)ab"),
  ]
  mock.offset = "repeated"
  let client = TelegramDiscussionClient(transport: mock)
  let result = try await client.page(for: asset, offset: "repeated")
  #expect(result.nextOffset == nil)
  let exchanges = try #require(result.chats.first?.exchanges)
  #expect(exchanges.compactMap { $0.share?.prose } == ["My note", "Base discussion"])
  #expect(exchanges.map(\.chainUnconfirmed) == [true, false])
  #expect(exchanges.last?.share?.parts == [.text("Base discussion "), .cashtag])
  let exchange = try #require(exchanges.first)
  #expect(try await client.messageLink(exchange.id).absoluteString == mock.returnedLink)
  mock.returnedLink = "https://t.me@other.example/c/123"
  await #expect(throws: TelegramError.self) { try await client.messageLink(exchange.id) }
}

@Test @MainActor func telegramExchangeKeepsSeparateSharesAndLoadsScopedSurroundingMessages() async throws {
  let asset = Asset.backpack
  let mock = DiscussionTransportFixture()
  mock.bots = [400]
  mock.source(-100, "Markets", type: "chatTypeSupergroup")

  let share = mock.message(100, chat: -100, "Watching \(asset.id) here.", topic: 7, reply: 96)
  let another = mock.message(90, chat: -100, asset.id, topic: 7)
  let linkedLabel = mock.message(89, chat: -100, "Look at this market", topic: 7,
    link: "https://solscan.io/token/\(asset.id)")
  mock.matches = [share, another, linkedLabel]
  mock.nearby[100] = [
    mock.message(107, chat: -100, "After 2", topic: 7),
    mock.message(106, chat: -100, "Different topic", topic: 8),
    mock.message(105, chat: -100, "After 1", topic: 7),
    mock.message(104, chat: -101, "Different chat", topic: 7),
    mock.message(103, chat: -100, sender: 400, "Bot reply", topic: 7, reply: 100),
    mock.message(102, chat: -100, "damn", topic: 7, reply: 100),
    mock.message(101, chat: -100, "woah", topic: 7, reply: 100),
    share,
    mock.message(99, chat: -100, "Before 2", topic: 7),
    mock.message(98, chat: -100, "Protected", topic: 7, canBeSaved: false),
    mock.message(97, chat: -100, "Before 1", topic: 7),
    mock.message(96, chat: -100, "What is this token?", topic: 7),
  ]

  let client = TelegramDiscussionClient(transport: mock)
  let result = try await client.page(for: asset, offset: "")
  let exchanges = try #require(result.chats.first?.topics.first?.exchanges)
  #expect(exchanges.map { $0.id.message } == [100, 90, 89])
  let exchange = try #require(exchanges.first)
  #expect(exchange.share?.parts == [.text("Watching "), .cashtag, .text(" here.")])
  #expect(exchange.parent?.prose == "What is this token?")
  #expect(exchange.replies.map(\.prose) == ["woah", "damn"])
  #expect(exchanges[1].share?.parts == [.cashtag])
  #expect(exchanges[2].share?.parts == [.text("Look at this market"), .text(" "), .cashtag])

  let context = try await client.context(for: exchange, asset: asset, includeSurrounding: true)
  #expect(context.before.map(\.prose) == ["Before 1", "Before 2"])
  #expect(context.after.map(\.prose) == ["After 1", "After 2"])
  #expect(context.replies.map(\.prose) == ["woah", "damn"])
  #expect(mock.calls.last(where: { $0.0 == .getForumTopicHistory })?.1["forum_topic_id"]?.int == 7)

  let affected = result.removingChangedMessages([exchange.id])
  #expect(affected.chats.first?.topics.first?.exchanges.map { $0.id.message } == [90, 89])

  mock.messagesByID[100] = mock.message(100, chat: -100, "Edited share without the asset", topic: 7)
  await #expect(throws: TelegramError.self) {
    try await client.context(for: exchange, asset: asset, includeSurrounding: true)
  }
}

@Test @MainActor func bareSharePreviewsHumanContextAndMergesAutomatedSearchHit() async throws {
  let asset = Asset.backpack
  let mock = DiscussionTransportFixture()
  mock.bots = [400]
  mock.source(-100, "Markets", type: "chatTypeSupergroup")

  let original = mock.message(100, chat: -100, asset.id, topic: 7)
  let automated = mock.message(105, chat: -100, sender: 400, "Scanner \(asset.id)", topic: 7, reply: 100)
  mock.matches = [automated, original]
  mock.nearby[100] = [
    mock.message(110, chat: -100, "Further after", topic: 7),
    mock.message(108, chat: -100, "Closest after", topic: 7),
    mock.message(107, chat: -100, "Different topic", topic: 8),
    mock.message(106, chat: -100, "https://solscan.io/token/So11111111111111111111111111111111111111112", topic: 7),
    automated,
    mock.message(104, chat: -100, "Following this", topic: 7, reply: 100),
    original,
    mock.message(99, chat: -100, "So11111111111111111111111111111111111111112", topic: 7),
    mock.message(98, chat: -100, "Closest before", topic: 7),
    mock.message(97, chat: -100, "Further before", topic: 7),
  ]
  let client = TelegramDiscussionClient(transport: mock)
  let page = try await client.page(for: asset, offset: "")
  let exchanges = try #require(page.chats.first?.topics.first?.exchanges)

  #expect(exchanges.map { $0.id.message } == [100])
  let exchange = try #require(exchanges.first)
  #expect(exchange.share?.parts == [.cashtag])
  #expect(exchange.nearbyBefore?.prose == "Closest before")
  #expect(exchange.nearbyAfter?.prose == "Closest after")
  #expect(exchange.replies.map(\.prose) == ["Following this"])
  let context = try await client.context(for: exchange, asset: asset, includeSurrounding: true)
  #expect(context.before.map { $0.id.message } == [97, 98, 99])
  #expect(context.after.map { $0.id.message } == [106, 108, 110])

  // The human post may not have appeared on the same search page.
  mock.matches = [automated]
  mock.messagesByID[100] = original
  let older = try await client.page(for: asset, offset: "older")
  #expect(older.chats.first?.topics.first?.exchanges.map { $0.id.message } == [100])
  #expect(page.merging(older).chats.first?.topics.first?.exchanges.count == 1)
}
