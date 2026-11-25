import Foundation
import Testing

@testable import TradingWorkspace

@Test @MainActor func supportIssuesAndRepliesSurviveRelaunch() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appending(path: "Support/issues.json")
  let store = SupportIssueStore(fileURL: file)
  #expect(!store.loadFailed)
  let first = try store.create(subject: "Chart loaded blank", message: "It happened on Markets.")
  _ = try store.create(subject: "Portfolio question", message: "I have a question about my balance.")
  try store.reply(to: first, message: "It loaded on my next attempt.")

  let reopened = SupportIssueStore(fileURL: file)
  #expect(reopened.issues.map(\.subject) == ["Chart loaded blank", "Portfolio question"])
  #expect(reopened.issues.first?.messages.map(\.text) == [
    "It happened on Markets.", "It loaded on my next attempt.",
  ])
}
