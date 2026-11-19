import Foundation
import Observation

@MainActor @Observable
final class SwapQuoteStore {
  private(set) var quote: SwapQuote?
  private(set) var isLoading = false
  private(set) var error: String?
  private(set) var input: SwapQuoteInput?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private let fetch: @MainActor (SwapQuoteInput) async throws -> SwapQuote

  init(
    fetch: @escaping @MainActor (SwapQuoteInput) async throws -> SwapQuote = {
      try await SwapQuoteClient().fetch($0)
    }
  ) {
    self.fetch = fetch
  }
  func clear() {
    generation = UUID()
    task?.cancel()
    task = nil
    quote = nil
    input = nil
    error = nil
    isLoading = false
  }
  func load(_ input: SwapQuoteInput) {
    clear()
    guard input.isValid else { return }
    self.input = input
    isLoading = true
    let token = generation
    task = Task {
      do {
        let value = try await fetch(input)
        guard !Task.isCancelled, generation == token, self.input == input else { return }
        guard value.matches(input) else {
          error = "Quote identity could not be confirmed. Refresh to try again."
          isLoading = false
          return
        }
        quote = value
        isLoading = false
      } catch {
        guard !Task.isCancelled, generation == token else { return }
        self.error = error.localizedDescription
        isLoading = false
      }
    }
  }
  func visibleQuote(for input: SwapQuoteInput) -> SwapQuote? { self.input == input ? quote : nil }
}
