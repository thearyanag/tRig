import Observation

@MainActor @Observable final class ExecutionProviderStore {
  private(set) var providers: [ExecutionProviderInfo] = []
  private(set) var isLoading = false
  private(set) var error: String?

  func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      let result = try await ExecutionQuoteClient().providers()
      if !Task.isCancelled {
        providers = result
        error = nil
      }
    } catch {
      if !Task.isCancelled {
        self.error = "Available routes could not be refreshed. Try again shortly."
      }
    }
  }
}
