import Foundation
import Observation

@MainActor @Observable final class ExecutionQuoteStore {
  private(set) var providers: [ExecutionProviderInfo] = []
  private(set) var quote: ExecutionQuote?
  private(set) var request: ExecutionQuoteRequest?
  private(set) var error: String?
  private(set) var isLoading = false
  private(set) var isLoadingProviders = false
  private(set) var providerError: String?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private let fetch:
    @MainActor (ExecutionQuoteRequest) async throws -> ExecutionQuote
  init(
    fetch: @escaping @MainActor (ExecutionQuoteRequest) async throws -> ExecutionQuote = {
      try await ExecutionQuoteClient().quote($0)
    }
  ) { self.fetch = fetch }
  func loadProviders() async {
    isLoadingProviders = true
    defer { isLoadingProviders = false }
    do {
      let result = try await ExecutionQuoteClient().providers()
      if !Task.isCancelled {
        providers = result
        providerError = nil
      }
    } catch {
      if !Task.isCancelled {
        providerError = "Available routes could not be refreshed. Try again shortly."
      }
    }
  }
  func clear() {
    generation = UUID()
    task?.cancel()
    task = nil
    quote = nil
    request = nil
    error = nil
    isLoading = false
  }
  func load(_ request: ExecutionQuoteRequest) {
    clear()
    guard request.isValid else { return }
    self.request = request
    isLoading = true
    let id = generation
    task = Task {
      do {
        let result = try await fetch(request)
        guard !Task.isCancelled, generation == id, self.request == request else { return }
        guard result.matches(request) else {
          error = "Quote identity could not be confirmed. Try refreshing."
          isLoading = false
          return
        }
        quote = result
        isLoading = false
      } catch {
        guard !Task.isCancelled, generation == id else { return }
        self.error = error.localizedDescription
        isLoading = false
      }
    }
  }
  func visible(for request: ExecutionQuoteRequest) -> ExecutionQuote? {
    self.request == request ? quote : nil
  }
}
