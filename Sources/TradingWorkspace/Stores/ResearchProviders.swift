import Foundation
import Observation

@MainActor @Observable
final class ResearchProviders {
  static let shared = ResearchProviders()

  private(set) var installed: [ResearchProvider: Bool] = [:]
  private(set) var catalogs: [ResearchProvider: ResearchCatalog] = [:]
  private(set) var checking: Set<ResearchProvider> = []
  private(set) var connectionErrors: [ResearchProvider: String] = [:]
  private(set) var serviceError: String?

  func restore(_ provider: ResearchProvider) async {
    guard UserDefaults.standard.bool(forKey: preference(for: provider)),
      catalogs[provider] == nil, connectionErrors[provider] == nil else { return }
    await check(provider)
  }

  func detect() async {
    do {
      let found = try await ResearchClient.installations()
      guard !Task.isCancelled else { return }
      installed = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.installed) })
      catalogs = catalogs.filter { installed[$0.key] == true }
      serviceError = nil
    } catch {
      if !Task.isCancelled { serviceError = error.localizedDescription }
    }
  }

  func check(_ provider: ResearchProvider) async {
    guard checking.insert(provider).inserted else { return }
    connectionErrors[provider] = nil
    defer { checking.remove(provider) }
    do {
      let catalog = try await ResearchClient.probe(provider)
      guard !Task.isCancelled else { return }
      catalogs[provider] = catalog
      UserDefaults.standard.set(true, forKey: preference(for: provider))
    } catch {
      guard !Task.isCancelled else { return }
      catalogs[provider] = nil
      connectionErrors[provider] = error.localizedDescription
    }
  }

  private func preference(for provider: ResearchProvider) -> String { "research.checked.\(provider.rawValue)" }
}
