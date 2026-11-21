import Foundation
import WebKit

@MainActor
struct PumpPortfolioClient {
  let session: ConnectionBrowserSession

  func read(period: PortfolioPeriod) async throws -> PortfolioProviderPayload {
    guard let wallet = session.profile?.wallet else {
      throw PortfolioReadFailure(message: "Connect Pumpfun in Settings to load its portfolio.")
    }
    let cookieStore = session.webView.configuration.websiteDataStore.httpCookieStore
    let cookie = try ConnectionProfileRules.pumpCookie(in: await cookieStore.allCookies())
    guard cookie.path == "/" else {
      throw PortfolioReadFailure(message: "Reconnect Pumpfun to allow portfolio reads.")
    }
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    config.timeoutIntervalForRequest = 35
    config.timeoutIntervalForResource = 45
    let http = URLSession(
      configuration: config, delegate: ConnectionRedirectGuard(), delegateQueue: nil)
    defer { http.invalidateAndCancel() }
    let summary = try await get(
      "portfolio-summary",
      query: [
        URLQueryItem(name: "period", value: period.pumpPeriod),
        URLQueryItem(name: "holdings", value: "1"),
      ], cookie: cookie, http: http)
    guard summary["wallet"] as? String == wallet else {
      throw PortfolioReadFailure(message: "The Pumpfun account changed. Refresh to confirm it.")
    }
    var positions: [[String: Any]] = []
    var complete = false
    let deadline = Date().addingTimeInterval(90)
    for page in 0..<20 {
      if Date() > deadline { break }
      try Task.checkCancellation()
      let result = try await get(
        "user-portfolio/\(wallet)",
        query: [
          URLQueryItem(name: "filter", value: "OPEN"),
          URLQueryItem(name: "sortBy", value: "POSITION_SIZE"),
          URLQueryItem(name: "page", value: String(page)),
          URLQueryItem(name: "pageSize", value: "200"),
        ], cookie: cookie, http: http)
      guard let rows = result["positions"] as? [[String: Any]] else {
        throw PortfolioReadFailure(message: "Pumpfun returned an unexpected holdings response.")
      }
      if rows.isEmpty {
        complete = true
        break
      }
      positions += rows.map(cleanPosition)
      if page < 19 { try await Task.sleep(for: .seconds(1)) }
    }
    var history: [[String: Any]] = []
    var warnings: [String] = []
    do {
      let result = try await get(
        "portfolio-summary/chart", query: [URLQueryItem(name: "period", value: period.pumpPeriod)],
        cookie: cookie, http: http)
      history = (result["points"] as? [[String: Any]] ?? []).map { pick($0, ["time", "value"]) }
    } catch is CancellationError { throw CancellationError() } catch {
      warnings.append("Pumpfun's portfolio history could not refresh.")
    }
    try Task.checkCancellation()
    let current = try ConnectionProfileRules.pumpCookie(in: await cookieStore.allCookies())
    guard current.value == cookie.value, current.domain == cookie.domain,
      current.path == cookie.path,
      session.profile?.wallet == wallet
    else { throw PortfolioReadFailure(message: "The Pumpfun session changed during refresh.") }
    var data = pick(
      summary,
      [
        "wallet", "evmAddress", "totalValueUsd", "pnl", "percentage", "unrealizedPnl",
        "nativeBalanceSol", "solPriceUsd", "unpriced", "unpricedCount", "computedAt",
      ])
    data["holdings"] = (summary["holdings"] as? [[String: Any]] ?? []).map {
      pick($0, ["chain", "mint", "amount", "priceUsd", "valueUsd"])
    }
    if let reprice = summary["reprice"] as? [String: Any] {
      data["reprice"] = pick(reprice, ["unrepriced"])
    }
    var envelope: [String: Any] = [
      "data": [
        "summary": data, "positions": positions, "positionsComplete": complete, "history": history,
        "warnings": warnings,
      ]
    ]
    if let evm = summary["evmAddress"] as? String, ConnectionProfileRules.isWallet(evm) {
      envelope["evmWallet"] = evm
    }
    return PortfolioProviderPayload(
      source: .pump, wallet: wallet, period: period,
      data: try JSONSerialization.data(withJSONObject: envelope), fetchedAt: Date())
  }

  private func get(_ path: String, query: [URLQueryItem], cookie: HTTPCookie, http: URLSession)
    async throws -> [String: Any]
  {
    var components = URLComponents(
      url: ConnectionProfileRules.pumpAPI.appendingPathComponent(path),
      resolvingAgainstBaseURL: false)!
    components.queryItems = query
    var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(
      HTTPCookie.requestHeaderFields(with: [cookie])["Cookie"], forHTTPHeaderField: "Cookie")
    let (bytes, response) = try await http.data(for: request)
    try Task.checkCancellation()
    guard let response = response as? HTTPURLResponse else {
      throw PortfolioReadFailure(message: "Pumpfun could not be reached.")
    }
    if [401, 403].contains(response.statusCode) {
      throw PortfolioReadFailure(message: "Pumpfun needs you to sign in again in Settings.")
    }
    if response.statusCode == 429 {
      throw PortfolioReadFailure(
        message: "Pumpfun requested a cooldown. Try refreshing again shortly.")
    }
    guard response.statusCode == 200, bytes.count <= 8 * 1024 * 1024,
      let result = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    else {
      throw PortfolioReadFailure(message: "Pumpfun portfolio data is temporarily unavailable.")
    }
    return result
  }
  private func pick(_ value: [String: Any], _ keys: [String]) -> [String: Any] {
    value.filter { keys.contains($0.key) }
  }
  private func cleanPosition(_ row: [String: Any]) -> [String: Any] {
    var result = pick(
      row,
      [
        "coinMint", "chainId", "chain", "amountHeld", "tokenPriceUsd", "valueUsd", "costBasisUsd",
        "hasUntrustedUsdBasis", "isNative", "potentialSpam", "userMarkedNonSpam",
        "dustFloorFiltered", "walletAddress", "assetClass", "perp",
      ])
    // Social/callout content is deliberately not carried into portfolio data.
    if let coin = row["coin"] as? [String: Any] {
      result["coin"] = pick(coin, ["name", "symbol", "imageUri"])
    }
    if row["perp"] is [String: Any] { result["perp"] = ["present": true] }
    return result
  }
}
