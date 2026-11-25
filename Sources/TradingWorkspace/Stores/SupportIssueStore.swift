import Foundation
import Observation

struct SupportIssue: Codable, Identifiable {
  struct Message: Codable, Identifiable {
    var id = UUID()
    var date = Date.now
    let text: String
  }

  var id = UUID()
  let subject: String
  var messages: [Message]
}

@MainActor @Observable
final class SupportIssueStore {
  static let shared = SupportIssueStore(
    fileURL: .applicationSupportDirectory.appending(path: "com.aryan.TradingWorkspace/Support/issues.json"))

  private(set) var issues: [SupportIssue] = []
  private(set) var loadFailed = false
  private let fileURL: URL

  init(fileURL: URL) {
    self.fileURL = fileURL
    do {
      let data = try Data(contentsOf: fileURL)
      issues = try JSONDecoder().decode([SupportIssue].self, from: data)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      // The file is created when the first issue is saved.
    } catch {
      loadFailed = true
    }
  }

  func create(subject: String, message: String) throws -> SupportIssue.ID {
    let issue = SupportIssue(subject: subject, messages: [.init(text: message)])
    try save([issue] + issues)
    return issue.id
  }

  func reply(to id: SupportIssue.ID, message: String) throws {
    var updated = issues
    guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
    var issue = updated.remove(at: index)
    issue.messages.append(.init(text: message))
    updated.insert(issue, at: 0)
    try save(updated)
  }

  private func save(_ updated: [SupportIssue]) throws {
    guard !loadFailed else { throw CocoaError(.fileWriteUnknown) }
    let data = try JSONEncoder().encode(updated)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try data.write(to: fileURL, options: .atomic)
    issues = updated
  }
}
