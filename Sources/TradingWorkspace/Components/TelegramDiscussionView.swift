import SwiftUI

struct TelegramDiscussionView: View {
  private struct Scope: Equatable {
    let asset: String
    let session: UUID
  }
  private struct Request: Equatable {
    var token = UUID()
    var offset = ""
  }
  private struct TopicSelection: Hashable {
    let chat: Int64
    let topic: Int64
  }

  let asset: Asset
  let session: TelegramSession
  @State private var request = Request()
  @State private var loadedScope: Scope?
  @State private var page: TelegramDiscussionPage?
  @State private var busy = false
  @State private var error: String?
  @State private var updated: Date?
  @State private var openChats: Set<Int64> = []
  @State private var openTopics: Set<TopicSelection> = []
  @State private var userCollapsedAll = false

  private var scope: Scope { Scope(asset: asset.identity, session: session.epoch) }
  private var visiblePage: TelegramDiscussionPage? {
    session.isConnected && loadedScope == scope ? page : nil
  }
  private var chats: [TelegramDiscussionChat] { visiblePage?.chats ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Telegram discussion").font(AppTypography.font(size: 16, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
          if !chats.isEmpty {
            Text(sourceCount).font(AppTypography.caption).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        if session.isConnected {
          Button {
            request = Request()
          } label: {
            Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
          }
          .buttonStyle(.plain).foregroundStyle(.secondary).disabled(busy)
          .help("Refresh Telegram discussion").accessibilityLabel("Refresh Telegram discussion")
        }
      }
      .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 10)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 9) {
          if !session.isConnected {
            connectionPrompt
          } else if chats.isEmpty {
            emptyState
          } else {
            ForEach(chats) { chat in chatRow(chat) }
          }
          if session.isConnected, let offset = visiblePage?.nextOffset {
            Button("Load older results") { request = Request(offset: offset) }
              .buttonStyle(.link).font(AppTypography.caption).disabled(busy)
          }
          if session.isConnected, visiblePage?.incomplete == true {
            Text("Some discussion previews couldn’t be loaded.")
              .font(AppTypography.caption).foregroundStyle(.orange)
          }
          if session.isConnected, let error, !chats.isEmpty {
            Text(error).font(AppTypography.caption).foregroundStyle(.orange)
          }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if session.isConnected, let updated, loadedScope == scope {
        Divider()
        HStack(spacing: 5) {
          if busy { ProgressView().controlSize(.mini) }
          Text(busy ? "Checking Telegram…" : "Updated " + updated.formatted(date: .omitted, time: .shortened))
            .font(AppTypography.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
      }
    }
    .task(id: scope.asset + scope.session.uuidString + request.token.uuidString) {
      guard session.isConnected else { return }
      await search(scope: scope, request: request)
    }
    .onChange(of: session.lastChange) { _, change in
      guard let change, chats.contains(where: { chat in
        chat.allExchanges.contains { !change.messages.isDisjoint(with: $0.displayedIDs) }
      }) else { return }
      page = nil
      request = Request()
    }
  }

  private var connectionPrompt: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("See what your Telegram chats are saying about \(asset.symbol).")
        .font(AppTypography.callout).foregroundStyle(.secondary)
      SettingsLink { Text("Connect Telegram") }
        .buttonStyle(TerminalControlStyle()).controlSize(.small)
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder private var emptyState: some View {
    if busy || visiblePage == nil && error == nil {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Looking for discussion…")
      }
      .font(AppTypography.callout).foregroundStyle(.secondary)
    } else if let error {
      Text(error).font(AppTypography.callout).foregroundStyle(.orange)
      Button("Try again") { request = Request() }.buttonStyle(.link)
        .font(AppTypography.callout)
    } else if visiblePage?.nextOffset != nil || visiblePage?.incomplete == true {
      Text("No matching discussion in these results yet.")
        .font(AppTypography.callout).foregroundStyle(.secondary)
    } else {
      Text("No discussion found for \(asset.symbol).")
        .font(AppTypography.callout).foregroundStyle(.secondary)
    }
  }

  private func chatRow(_ chat: TelegramDiscussionChat) -> some View {
    let expanded = openChats.contains(chat.id)
    return VStack(alignment: .leading, spacing: 0) {
      Button {
        toggleChat(chat)
      } label: {
        VStack(alignment: .leading, spacing: 7) {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: chat.kind == .group ? "person.2" : "person")
              .font(AppTypography.caption).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
              Text(verbatim: chat.title).font(AppTypography.calloutMedium).lineLimit(1)
              Text(chat.kind.rawValue).font(AppTypography.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let date = chat.latest?.latest { timestamp(date) }
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .font(.system(size: 9)).foregroundStyle(.secondary)
          }
          if !expanded, let exchange = chat.latest { exchangePreview(exchange, chat: chat) }
        }
        .padding(9).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint(expanded ? "Collapse conversation" : "Expand conversation")

      if expanded {
        Divider().padding(.horizontal, 9)
        VStack(alignment: .leading, spacing: 9) {
          if !chat.exchanges.isEmpty { exchangeList(chat.exchanges, chat: chat) }
          ForEach(chat.topics) { topic in topicRow(topic, chat: chat) }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
      }
    }
    .background(expanded ? TerminalStyle.panel : TerminalStyle.canvas,
      in: RoundedRectangle(cornerRadius: 5))
    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
      expanded ? TerminalStyle.accent.opacity(0.55) : TerminalStyle.border))
  }

  private func topicRow(_ topic: TelegramDiscussionTopic, chat: TelegramDiscussionChat) -> some View {
    let key = TopicSelection(chat: chat.id, topic: topic.id)
    let expanded = openTopics.contains(key)
    return VStack(alignment: .leading, spacing: 7) {
      Button {
        if expanded { openTopics.remove(key) } else { openTopics.insert(key) }
      } label: {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Image(systemName: "number").foregroundStyle(.secondary)
            Text(verbatim: topic.title).font(AppTypography.calloutMedium).lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .font(.system(size: 9)).foregroundStyle(.secondary)
          }
          .font(AppTypography.caption)
          if !expanded, let exchange = topic.latest { exchangePreview(exchange, chat: chat) }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint(expanded ? "Collapse topic" : "Expand topic")
      if expanded {
        exchangeList(topic.exchanges, chat: chat).padding(.leading, 10)
      }
    }
    .padding(.leading, 8)
  }

  @ViewBuilder
  private func exchangePreview(_ exchange: TelegramExchange, chat: TelegramDiscussionChat) -> some View {
    if let quote = exchange.preview, !quote.prose.isEmpty {
      let prefix = chat.kind == .group ? quote.author + ": " : ""
      Text(verbatim: prefix + quote.prose)
        .font(AppTypography.caption).foregroundStyle(.secondary)
        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 3)
    } else {
      TelegramCashtagView(asset: asset)
    }
  }

  private func exchangeList(_ exchanges: [TelegramExchange], chat: TelegramDiscussionChat) -> some View {
    TelegramExchangeList(exchanges: exchanges, asset: asset, session: session,
      supportsMessageLink: chat.supportsMessageLink)
  }

  private func timestamp(_ date: Date) -> some View {
    let value = Calendar.current.isDateInToday(date)
      ? date.formatted(date: .omitted, time: .shortened)
      : Calendar.current.isDateInYesterday(date) ? "Yesterday"
      : date.formatted(.dateTime.month(.abbreviated).day())
    return Text(value).font(AppTypography.caption).monospacedDigit().foregroundStyle(.secondary)
  }

  private var sourceCount: String {
    let groups = chats.filter { $0.kind == .group }.count
    let direct = chats.count - groups
    return [groups == 0 ? nil : "\(groups) \(groups == 1 ? "group" : "groups")",
      direct == 0 ? nil : "\(direct) \(direct == 1 ? "direct message" : "direct messages")"]
      .compactMap { $0 }.joined(separator: " · ")
  }

  private func toggleChat(_ chat: TelegramDiscussionChat) {
    if openChats.remove(chat.id) != nil {
      userCollapsedAll = openChats.isEmpty
      return
    }
    openChats.insert(chat.id)
    if let topic = chat.topics.first,
      !openTopics.contains(where: { $0.chat == chat.id }) {
      openTopics.insert(TopicSelection(chat: chat.id, topic: topic.id))
    }
  }

  private func search(scope: Scope, request: Request) async {
    loadedScope = scope
    busy = true
    error = nil
    do {
      let result = try await session.discussion(for: asset, offset: request.offset)
      try Task.checkCancellation()
      guard loadedScope == scope, self.request == request else { return }
      page = request.offset.isEmpty ? result : page?.merging(result) ?? result
      updated = .now
      if openChats.isEmpty, !userCollapsedAll, let first = page?.chats.first {
        toggleChat(first)
      }
    } catch {
      guard !Task.isCancelled, loadedScope == scope, self.request == request else { return }
      self.error = error.localizedDescription
    }
    if loadedScope == scope, self.request == request { busy = false }
  }

}
