import Foundation
import Observation

@MainActor @Observable
final class ResearchConversationStore {
  private(set) var messages: [ResearchMessage] = []
  private(set) var conversation: ResearchConversation?
  private let firstConversationID = UUID()
  private(set) var turnID: UUID?
  private(set) var canStop = false
  private(set) var stopping = false
  private(set) var restoring = false
  private(set) var restored = false
  private(set) var error: String?
  var isResponding: Bool { turnID != nil }

  @ObservationIgnored private var worker: Task<Void, Never>?

  func restore() async {
    guard !restored, !restoring else { return }
    restoring = true
    error = nil
    defer { restoring = false }
    do {
      let snapshot = try await ResearchClient.conversation()
      try Task.checkCancellation()
      conversation = snapshot.conversation
      messages = snapshot.messages
      restored = true
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }

  func send(asset: Asset, provider: ResearchProvider, model: String?, question: String, telegram: TelegramSession) {
    guard restored, !isResponding, conversation?.provider == nil || conversation?.provider == provider else { return }
    let turn = ResearchTurn(asset: asset.identity, assetSymbol: asset.symbol, assetName: asset.name,
      assetNetwork: asset.network, assetPool: asset.hasChart ? asset.pool : nil,
      threadId: conversation?.id ?? firstConversationID, turnId: UUID(),
      provider: provider, model: model, question: question)
    turnID = turn.turnId
    canStop = false
    stopping = false
    error = nil
    messages.append(.init(role: .user, text: question))
    let reply = messages.endIndex
    messages.append(.init(role: .assistant, text: ""))
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        try await ResearchClient.stream(turn, asset: asset, telegram: telegram) { event in
          guard self.turnID == turn.turnId else { return }
          switch event.type {
          case "starting": self.canStop = true
          case "conversation":
            if let conversation = event.conversation { self.conversation = conversation }
          case "delta": self.messages[reply].text += event.text ?? ""
          case "error": self.error = event.message ?? "The response couldn’t be completed."
          default: break
          }
        }
      } catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
      if self.messages[reply].text.isEmpty { self.messages.remove(at: reply) }
      self.turnID = nil
      self.canStop = false
      self.stopping = false
      self.worker = nil
    }
  }

  func stop() async {
    guard let turnID, canStop, !stopping else { return }
    stopping = true
    do { try await ResearchClient.stop(thread: conversation?.id ?? firstConversationID, turn: turnID) }
    catch {
      if self.turnID == turnID {
        worker?.cancel()
        self.error = error.localizedDescription
      }
    }
  }
}
