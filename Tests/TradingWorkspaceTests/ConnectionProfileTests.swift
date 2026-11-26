import Foundation
import Testing

@testable import TradingWorkspace

private let connectionWallet = "So11111111111111111111111111111111111111112"
private func connectionCookie(
  domain: String = ".pump.fun", path: String = "/", name: String = "auth_token",
  secure: Bool = true, expired: Bool = false
) -> HTTPCookie {
  var values: [HTTPCookiePropertyKey: Any] = [
    .domain: domain, .path: path, .name: name,
    .value: "synthetic-test-only", .expires: Date().addingTimeInterval(expired ? -60 : 3600),
  ]
  if secure { values[.secure] = "TRUE" }
  return HTTPCookie(properties: values)!
}

@Test func connectionServicesKeepSeparatePersistentWebsiteStores() {
  #expect(ConnectionService.fomo.storeID != ConnectionService.pump.storeID)
  #expect(ConnectionService.fomo.homeURL.host == "fomo.family")
  #expect(ConnectionService.pump.homeURL.host == "pump.fun")
}

@Test func profileLinksUseHandlesForFomoAndWalletsForPumpfun() {
  let profile = ConnectedProfile(username: "_test.trader", wallet: connectionWallet, checkedAt: Date())
  #expect(ConnectionService.fomo.profileURL(for: profile)?.absoluteString
    == "https://fomo.family/profile/_test.trader")
  #expect(ConnectionService.pump.profileURL(for: profile)?.absoluteString
    == "https://pump.fun/profile/\(connectionWallet)")

  let unnamed = ConnectedProfile(username: nil, wallet: connectionWallet, checkedAt: Date())
  #expect(ConnectionService.fomo.profileURL(for: unnamed) == nil)
  #expect(ConnectionService.pump.profileURL(for: unnamed) == ConnectionService.pump.profileURL(for: profile))

  let invalid = ConnectedProfile(username: "../settings", wallet: "../settings", checkedAt: Date())
  #expect(ConnectionService.fomo.profileURL(for: invalid) == nil)
  #expect(ConnectionService.pump.profileURL(for: invalid) == nil)
}

@Test func pumpConnectionOnlyUsesItsScopedLiveCookie() throws {
  let chosen = try ConnectionProfileRules.pumpCookie(in: [
    connectionCookie(domain: ".google.com"), connectionCookie(name: "privy-token"),
    connectionCookie(),
  ])
  #expect(chosen.name == "auth_token")
  for bad in [
    connectionCookie(domain: ".pump.fun.evil.example"), connectionCookie(domain: ".fomo.family"),
    connectionCookie(path: "/auth/my"), connectionCookie(expired: true),
    connectionCookie(secure: false),
  ] {
    #expect(throws: ConnectionFailure.self) { try ConnectionProfileRules.pumpCookie(in: [bad]) }
  }
  #expect(throws: ConnectionFailure.self) {
    try ConnectionProfileRules.pumpCookie(in: [
      connectionCookie(), connectionCookie(domain: "frontend-api-v3.pump.fun"),
    ])
  }
}
@Test func pumpProfileMustMatchTheAuthenticatedIdentity() throws {
  let identity = PumpConnectionIdentity(address: connectionWallet, userId: "one")
  let profile = try ConnectionProfileRules.pumpProfile(
    identity: identity,
    user: PumpConnectionUser(address: connectionWallet, userId: "one", username: "example"))
  #expect(profile.username == "example")
  #expect(profile.wallet == connectionWallet)
  #expect(throws: ConnectionFailure.self) {
    try ConnectionProfileRules.pumpProfile(
      identity: identity,
      user: PumpConnectionUser(address: connectionWallet, userId: "other", username: "other"))
  }
}
@Test func fomoConnectionRequiresMatchingSessionAccountAndWallet() throws {
  let id = "11111111-1111-4111-8111-111111111111"
  var value: [String: Any] = [
    "state": "connected", "expectedID": id, "id": id,
    "username": "example", "wallet": connectionWallet, "sessionWallet": connectionWallet,
  ]
  #expect(try ConnectionProfileRules.fomoProfile(value)?.username == "example")
  value["id"] = "22222222-2222-4222-8222-222222222222"
  #expect(throws: ConnectionFailure.self) { try ConnectionProfileRules.fomoProfile(value) }
  value["id"] = id
  value["sessionWallet"] = "11111111111111111111111111111111"
  #expect(throws: ConnectionFailure.self) { try ConnectionProfileRules.fomoProfile(value) }
  #expect(try ConnectionProfileRules.fomoProfile(["state": "anonymous"]) == nil)
  #expect(try ConnectionProfileRules.fomoProfile(["state": "loading"]) == nil)
  #expect(throws: ConnectionFailure.self) {
    try ConnectionProfileRules.fomoProfile(["state": "unavailable"])
  }
}
