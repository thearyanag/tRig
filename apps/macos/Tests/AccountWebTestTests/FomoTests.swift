import Foundation
import Testing
@testable import AccountWebTest

struct FomoTests {
    func cookie(_ name: String = "privy-token", domain: String = ".fomo.family", path: String = "/", value: String = "synthetic", expired: Bool = false) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: path, .expires: Date().addingTimeInterval(expired ? -60 : 60)])!
    }
    @Test func cookieScopeNeverLeaksOtherServiceOrRefreshCredentials() throws {
        let selected = try FomoRules.cookies([cookie(), cookie("privy-session"), cookie("privy-refresh-token"), cookie(domain: ".privy.fomo.family"), cookie(domain: ".pump.fun"), cookie(domain: ".google.com")], url: FomoRules.api)
        #expect(Set(selected.map(\.name)) == ["privy-token", "privy-session"])
        for host in ["http://prod-api.fomo.family", "https://evil.example", "https://prod-api.fomo.family:444", "https://user@prod-api.fomo.family"] {
            #expect(throws: FomoFailure.self) { try FomoRules.cookies([cookie()], url: URL(string: host)!) }
        }
        #expect(throws: FomoFailure.self) { try FomoRules.cookies([cookie(expired: true)], url: FomoRules.api) }
        #expect(throws: FomoFailure.self) { try FomoRules.cookies([cookie(), cookie()], url: FomoRules.api) }
        #expect(throws: FomoFailure.self) { try FomoRules.cookies([cookie(path: "/auth")], url: FomoRules.api.appendingPathComponent("trades")) }
    }
    @Test func handleValidationPreservesOnlyTheProfileIdentifier() throws {
        #expect(try FomoRules.handle("https://fomo.family/profile/example_trader") == "example_trader")
        #expect(try FomoRules.handle(" example_trader ") == "example_trader")
        for input in ["https://fomo.family.evil.example/profile/test", "../users", "https://fomo.family/profile/a/b", "https://user@fomo.family/profile/test"] {
            #expect(throws: FomoFailure.self) { try FomoRules.handle(input) }
        }
    }
    @Test func retryAfterSupportsSecondsAndHTTPDates() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(FomoRules.retryDate("120", now: now) == now.addingTimeInterval(120))
        #expect(FomoRules.retryDate("Thu, 01 Jan 1970 00:02:00 GMT", now: now) == now.addingTimeInterval(120))
        #expect(FomoRules.retryDate("invalid", now: now) == nil)
        #expect(FomoRules.retryDate("-5", now: now) == nil)
    }
    @Test func sessionFingerprintChangesWhenAccountCredentialChanges() throws {
        #expect(try FomoRules.sessionFingerprint([cookie(), cookie("privy-session")]) == FomoRules.sessionFingerprint([cookie("privy-session"), cookie()]))
        #expect(try FomoRules.sessionFingerprint([cookie(value: "one")]) != FomoRules.sessionFingerprint([cookie(value: "two")]))
    }
    @Test func parsesTradeAndThesisWithoutNeedingPrivateFields() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        let row: [String: Any] = ["trade": ["id": id, "tokenAddress": "11111111111111111111111111111111", "userAddress": "owner", "closedAt": NSNull(), "tokenMetadata": ["symbol": "TEST"]], "comment": ["id": "comment", "comment": "Example"]]
        let trade = try #require(FomoRules.trade(row))
        #expect(!trade.closed)
        #expect(trade.symbol == "TEST")
        #expect(FomoRules.thesis(row)?.text == "Example")
        #expect(FomoRules.trade(["trade": ["id": "../../invalid"]]) == nil)
    }
    @Test func draftMustMatchProfilesWalletAndBeNonemptySolanaText() throws {
        let profile = FomoProfile(id: "p", handle: "test", displayName: "Test", avatar: nil, address: "owner")
        let trade = FomoTrade(id: "11111111-1111-4111-8111-111111111111", token: "11111111111111111111111111111111", symbol: "TEST", wallet: "owner", closed: false, comment: nil)
        try FomoRules.validateDraft(trade: trade, profile: profile, text: "Example")
        #expect(throws: FomoFailure.self) { try FomoRules.validateDraft(trade: trade, profile: profile, text: " \n") }
        #expect(throws: FomoFailure.self) { try FomoRules.validateDraft(trade: trade, profile: profile, text: String(repeating: "x", count: 1001)) }
        let other = FomoProfile(id: "other", handle: "other", displayName: "Other", avatar: nil, address: "another-wallet")
        #expect(throws: FomoFailure.self) { try FomoRules.validateDraft(trade: trade, profile: other, text: "Example") }
        let a = FomoDraft(trade: trade, profile: profile, text: "Example", sessionFingerprint: "a")
        let b = FomoDraft(trade: trade, profile: profile, text: "Example", sessionFingerprint: "b")
        #expect(a.attemptKey == b.attemptKey)
    }
}
