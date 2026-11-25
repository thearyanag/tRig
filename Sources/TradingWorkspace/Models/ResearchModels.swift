import Foundation

enum ResearchProvider: String, Codable, CaseIterable, Identifiable {
  case codex, grok = "grok-build", antigravity

  var id: Self { self }
  var name: String {
    switch self {
    case .codex: "Codex"
    case .grok: "Grok Build"
    case .antigravity: "Antigravity"
    }
  }
  var signInCommand: String {
    switch self {
    case .codex: "codex login"
    case .grok: "grok login"
    case .antigravity: "agy"
    }
  }
  var setupURL: URL {
    switch self {
    case .codex: URL(string: "https://developers.openai.com/codex/cli")!
    case .grok: URL(string: "https://docs.x.ai/build/overview")!
    case .antigravity: URL(string: "https://antigravity.google/docs/cli-install")!
    }
  }
  static var enabledInBuild: Bool {
    Bundle.main.object(forInfoDictionaryKey: "TRIGUseDataLaunchAgent") as? Bool == true
  }
}

struct ResearchModel: Decodable, Identifiable, Equatable {
  let id: String
  let name: String
}

struct ResearchInstallation: Decodable {
  let id: ResearchProvider
  let installed: Bool
}

struct ResearchCatalog: Decodable {
  let models: [ResearchModel]
}

struct ResearchConversation: Decodable {
  let id: UUID
  let provider: ResearchProvider
  let model: String?
}

struct ResearchSnapshot: Decodable {
  let conversation: ResearchConversation?
  let messages: [ResearchMessage]
}

struct ResearchMessage: Decodable, Identifiable {
  enum Role: String, Decodable { case user, assistant, error }

  var id = UUID()
  let role: Role
  var text: String

  enum CodingKeys: String, CodingKey { case role, text }
}

struct ResearchTurn: Encodable {
  let asset: String
  let assetSymbol: String
  let assetName: String
  let assetNetwork: String
  let assetPool: String?
  let threadId: UUID
  let turnId: UUID
  let provider: ResearchProvider
  let model: String?
  let question: String
}

struct ResearchEvent: Decodable {
  let type: String
  let conversation: ResearchConversation?
  let text: String?
  let status: String?
  let message: String?
  let requestId: UUID?
  let asset: String?
}
