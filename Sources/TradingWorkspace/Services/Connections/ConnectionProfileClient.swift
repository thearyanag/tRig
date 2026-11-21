import Foundation

struct PumpConnectionIdentity: Decodable {
  let address: String
  let userId: String?
}
struct PumpConnectionUser: Decodable {
  let address: String
  let userId: String?
  let username: String?
}

enum ConnectionProfileRules {
  static let pumpAPI = URL(string: "https://frontend-api-v3.pump.fun")!
  static let pumpIdentityURL = pumpAPI.appendingPathComponent("auth/my-profile")

  static func isWallet(_ value: String) -> Bool {
    value.range(of: "^[1-9A-HJ-NP-Za-km-z]{32,44}$", options: .regularExpression) != nil
      || value.range(of: "^0x[0-9a-fA-F]{40}$", options: .regularExpression) != nil
  }
  static func pumpCookie(in cookies: [HTTPCookie], now: Date = Date()) throws -> HTTPCookie {
    let matches = cookies.filter { cookie in
      let domain = cookie.domain.lowercased()
      return [".pump.fun", ".frontend-api-v3.pump.fun", "frontend-api-v3.pump.fun"].contains(domain)
        && cookie.name == "auth_token" && !cookie.value.isEmpty && cookie.isSecure
        && (cookie.expiresDate.map { $0 > now } ?? true)
        && (cookie.path == "/" || pumpIdentityURL.path == cookie.path
          || pumpIdentityURL.path.hasPrefix(
            cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/"))
    }
    guard matches.count == 1 else {
      throw ConnectionFailure(
        message: matches.isEmpty
          ? "Finish signing in on Pumpfun, then try again."
          : "Pumpfun has multiple sessions. Sign out on its website and sign in again.")
    }
    return matches[0]
  }
  static func pumpProfile(identity: PumpConnectionIdentity, user: PumpConnectionUser) throws
    -> ConnectedProfile
  {
    guard isWallet(identity.address), !identity.address.hasPrefix("0x"),
      user.address == identity.address,
      identity.userId == nil || user.userId == nil || identity.userId == user.userId
    else {
      throw ConnectionFailure(
        message: "Pumpfun returned a different account. Reconnect and try again.")
    }
    return ConnectedProfile(username: user.username, wallet: identity.address, checkedAt: Date())
  }
  static func fomoProfile(_ value: Any) throws -> ConnectedProfile? {
    guard let row = value as? [String: Any], let state = row["state"] as? String else {
      throw ConnectionFailure(
        message: "Fomo's profile reader is unavailable. Reload its website and try again.")
    }
    if ["anonymous", "loading"].contains(state) { return nil }
    guard state == "connected", let expectedID = row["expectedID"] as? String,
      UUID(uuidString: expectedID) != nil, row["id"] as? String == expectedID,
      let wallet = row["wallet"] as? String, isWallet(wallet)
    else {
      throw ConnectionFailure(
        message: "Fomo could not confirm the connected profile. Reload and try again.")
    }
    if let sessionWallet = row["sessionWallet"] as? String, !sessionWallet.isEmpty,
      sessionWallet != wallet
    {
      throw ConnectionFailure(message: "Fomo's profile wallet does not match the signed-in wallet.")
    }
    return ConnectedProfile(username: row["username"] as? String, wallet: wallet, checkedAt: Date())
  }
}

final class ConnectionRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

struct PumpConnectionClient {
  func load(cookie: HTTPCookie) async throws -> ConnectedProfile {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    let session = URLSession(
      configuration: configuration, delegate: ConnectionRedirectGuard(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: ConnectionProfileRules.pumpIdentityURL)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(
      HTTPCookie.requestHeaderFields(with: [cookie])["Cookie"], forHTTPHeaderField: "Cookie")
    let identity: PumpConnectionIdentity = try await read(request, session: session)
    guard ConnectionProfileRules.isWallet(identity.address), !identity.address.hasPrefix("0x")
    else {
      throw ConnectionFailure(message: "Pumpfun returned an invalid account identity.")
    }
    var publicRequest = URLRequest(
      url: ConnectionProfileRules.pumpAPI.appendingPathComponent("users").appendingPathComponent(
        identity.address))
    publicRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    let user: PumpConnectionUser = try await read(publicRequest, session: session)
    return try ConnectionProfileRules.pumpProfile(identity: identity, user: user)
  }
  private func read<T: Decodable>(_ request: URLRequest, session: URLSession) async throws -> T {
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else {
      throw ConnectionFailure(message: "Pumpfun could not be reached.")
    }
    guard http.statusCode != 401 && http.statusCode != 403 else {
      throw ConnectionFailure(message: "Your Pumpfun session expired. Sign in again.")
    }
    guard (200..<300).contains(http.statusCode), data.count <= 1_000_000,
      let value = try? JSONDecoder().decode(T.self, from: data)
    else { throw ConnectionFailure(message: "Pumpfun could not read your profile. Try again.") }
    return value
  }
}
