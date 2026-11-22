import SwiftUI

struct TelegramExchangeList: View {
  let exchanges: [TelegramExchange]
  let asset: Asset
  let session: TelegramSession
  let supportsMessageLink: Bool

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 10) {
      ForEach(exchanges) { exchange in
        if exchange.id != exchanges.first?.id { Divider() }
        TelegramExchangeDetail(exchange: exchange, asset: asset, session: session,
          supportsMessageLink: supportsMessageLink)
      }
    }
  }
}

private struct TelegramExchangeDetail: View {
  let exchange: TelegramExchange
  let asset: Asset
  let session: TelegramSession
  let supportsMessageLink: Bool
  @Environment(\.openURL) private var openURL
  @State private var details: TelegramExchangeContext?
  @State private var nearby: TelegramExchangeContext?
  @State private var showSurrounding = false
  @State private var retryID = UUID()
  @State private var loadError: String?
  @State private var linkError = false
  @State private var openingSource = false
  @State private var linkTask: Task<Void, Never>?

  private struct ReadRequest: Hashable {
    let id: TelegramQuote.ID
    let includeSurrounding: Bool
    let revision: UUID
    let repliesLoaded: Bool
  }

  private var parent: TelegramQuote? {
    if let details { return details.parent }
    return exchange.parent
  }

  private var waitingForContext: Bool {
    guard loadError == nil else { return false }
    return showSurrounding ? nearby == nil : !exchange.repliesLoaded && details == nil
  }

  private var bareShare: Bool { exchange.share?.prose.isEmpty != false }

  private var before: [TelegramQuote] {
    if showSurrounding, let nearby { return nearby.before }
    guard bareShare else { return [] }
    let quote = details?.before.last(where: \.hasPreviewText) ?? exchange.nearbyBefore
    return quote.map { [$0] } ?? []
  }

  private var after: [TelegramQuote] {
    if showSurrounding, let nearby { return nearby.after }
    guard bareShare else { return [] }
    let quote = details?.after.first(where: \.hasPreviewText) ?? exchange.nearbyAfter
    return quote.map { [$0] } ?? []
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Rectangle().fill(TerminalStyle.border).frame(width: 2)
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
          if bareShare { TelegramCashtagView(asset: asset) }
          Text(exchange.date, format: .dateTime.month(.abbreviated).day().hour().minute())
            .font(AppTypography.caption).foregroundStyle(.secondary)
        }
        if showSurrounding { contextRows(before, title: "Before the share") }
        if let parent {
          Text("Replying to").font(AppTypography.caption).foregroundStyle(.secondary)
          quoteRow(parent)
        }
        if let share = exchange.share {
          if bareShare {
            Text(verbatim: share.author).font(AppTypography.caption).fontWeight(.medium)
          } else {
            quoteRow(share)
          }
          if exchange.chainUnconfirmed {
            Text("Chain unconfirmed").font(AppTypography.caption).foregroundStyle(.secondary)
          }
        } else {
          Text("Original share unavailable").font(AppTypography.caption).foregroundStyle(.secondary)
        }
        ForEach(details?.replies ?? exchange.replies) { quote in
          quoteRow(quote).padding(.leading, 8)
        }
        if !showSurrounding { contextRows(before, title: "Before the share") }
        contextRows(after, title: "After the share")
        if showSurrounding, let nearby, nearby.before.isEmpty, nearby.after.isEmpty {
          Text("No other messages in this window.")
            .font(AppTypography.caption).foregroundStyle(.secondary)
        }
        if waitingForContext {
          HStack(spacing: 5) {
            ProgressView().controlSize(.mini)
            Text(showSurrounding ? "Loading surrounding messages…" : "Loading replies…")
              .font(AppTypography.caption).foregroundStyle(.secondary)
          }
        }
        if let loadError {
          Text(loadError).font(AppTypography.caption).foregroundStyle(.orange)
          Button("Retry") { retryID = UUID() }.buttonStyle(.link).font(AppTypography.caption)
        }
        Divider()
        Button {
          showSurrounding.toggle()
          loadError = nil
        } label: {
          Label(showSurrounding ? "Hide surrounding messages" : "Show surrounding messages",
            systemImage: showSurrounding ? "chevron.up" : "chevron.down")
            .font(AppTypography.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)

        if supportsMessageLink, exchange.share != nil {
          Button(action: showSource) {
            Label("Open in Telegram", systemImage: "arrow.up.right")
              .font(AppTypography.caption)
          }
          .buttonStyle(.link).disabled(openingSource)
        }
        if linkError {
          Text("Telegram couldn’t open the original message.")
            .font(AppTypography.caption).foregroundStyle(.orange)
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .task(id: ReadRequest(id: exchange.id, includeSurrounding: showSurrounding, revision: retryID,
      repliesLoaded: exchange.repliesLoaded)) {
      await load(includeSurrounding: showSurrounding)
    }
    .onChange(of: session.lastChange) { _, change in
      guard let change else { return }
      let cachedIDs = (details?.quotes ?? []) + (nearby?.quotes ?? [])
      if cachedIDs.contains(where: { change.messages.contains($0.id) }) {
        details = nil
        nearby = nil
        retryID = UUID()
      }
    }
    .onDisappear { linkTask?.cancel() }
  }

  @ViewBuilder private func contextRows(_ messages: [TelegramQuote], title: String) -> some View {
    if !messages.isEmpty {
      Text(title).font(AppTypography.caption).foregroundStyle(.secondary)
      ForEach(messages) { quote in quoteRow(quote).padding(.leading, 8) }
      Divider()
    }
  }

  private func quoteRow(_ quote: TelegramQuote) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 5) {
        Text(verbatim: quote.author).font(AppTypography.caption).fontWeight(.medium).lineLimit(1)
        Text(quote.date, format: .dateTime.hour().minute())
          .font(AppTypography.caption).monospacedDigit().foregroundStyle(.secondary)
      }
      TelegramQuoteBody(quote: quote, asset: asset)
    }
  }

  private func load(includeSurrounding: Bool) async {
    guard includeSurrounding ? nearby == nil : !exchange.repliesLoaded && details == nil else {
      return
    }
    loadError = nil
    do {
      let result = try await session.context(for: exchange, asset: asset,
        includeSurrounding: includeSurrounding)
      try Task.checkCancellation()
      details = result
      if includeSurrounding { nearby = result }
    } catch {
      guard !Task.isCancelled else { return }
      loadError = includeSurrounding
        ? "Couldn’t load surrounding messages." : "Couldn’t load replies."
    }
  }

  private func showSource() {
    guard !openingSource else { return }
    openingSource = true
    linkError = false
    linkTask = Task {
      defer { openingSource = false }
      do {
        let url = try await session.link(for: exchange.id)
        try Task.checkCancellation()
        openURL(url)
      } catch {
        if !Task.isCancelled { linkError = true }
      }
    }
  }
}
