import Foundation
import Observation

@MainActor @Observable final class QuoteStore<Request: Equatable, Quote> {
  private var request: Request?
  private(set) var quote: Quote?
  private(set) var isLoading = false
  private(set) var error: String?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private let fetch: @MainActor (Request) async throws -> Quote
  @ObservationIgnored private let isValid: (Request) -> Bool
  @ObservationIgnored private let matches: (Quote, Request) -> Bool

  private init(
    fetch: @escaping @MainActor (Request) async throws -> Quote,
    isValid: @escaping (Request) -> Bool,
    matches: @escaping (Quote, Request) -> Bool
  ) {
    self.fetch = fetch
    self.isValid = isValid
    self.matches = matches
  }

  func load(_ request: Request) {
    clear()
    guard isValid(request) else { return }
    self.request = request
    isLoading = true
    task = Task { [weak self, fetch] in
      defer {
        if !Task.isCancelled {
          self?.isLoading = false
          self?.task = nil
        }
      }
      do {
        let result = try await fetch(request)
        guard !Task.isCancelled, let self else { return }
        if matches(result, request) {
          quote = result
        } else {
          error = "Quote identity could not be confirmed. Refresh to try again."
        }
      } catch {
        if !Task.isCancelled { self?.error = error.localizedDescription }
      }
    }
  }

  func requestDidChange(_ request: Request) {
    if self.request != request { clear() }
  }

  func clear() {
    task?.cancel()
    task = nil
    request = nil
    quote = nil
    isLoading = false
    error = nil
  }

  func visible(for request: Request) -> Quote? {
    self.request == request ? quote : nil
  }
}

typealias SwapQuoteStore = QuoteStore<SwapQuoteInput, SwapQuote>
typealias ExecutionQuoteStore = QuoteStore<ExecutionQuoteRequest, ExecutionQuote>

extension QuoteStore where Request == SwapQuoteInput, Quote == SwapQuote {
  convenience init(
    fetch: @escaping @MainActor (SwapQuoteInput) async throws -> SwapQuote = {
      try await SwapQuoteClient().fetch($0)
    }
  ) {
    self.init(fetch: fetch, isValid: \.isValid, matches: { $0.matches($1) })
  }
}

extension QuoteStore where Request == ExecutionQuoteRequest, Quote == ExecutionQuote {
  convenience init(
    fetch: @escaping @MainActor (ExecutionQuoteRequest) async throws -> ExecutionQuote = {
      try await ExecutionQuoteClient().quote($0)
    }
  ) {
    self.init(fetch: fetch, isValid: \.isValid, matches: { $0.matches($1) })
  }
}
