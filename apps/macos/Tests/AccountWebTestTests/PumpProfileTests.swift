import Foundation
import Testing
@testable import AccountWebTest

struct PumpProfileTests {
    let wallet = "11111111111111111111111111111111"
    func cookie(domain: String = ".pump.fun", path: String = "/", name: String = "auth_token", expired: Bool = false) -> HTTPCookie {
        HTTPCookie(properties: [.domain: domain, .path: path, .name: name, .value: "synthetic-test-only",
                               .secure: "TRUE", .expires: Date().addingTimeInterval(expired ? -60 : 3600)])!
    }

    @Test func choosesOnlyThePumpSession() throws {
        let cookies = [cookie(domain: ".google.com"), cookie(domain: ".fomo.family"),
                       cookie(name: "privy-token"), cookie()]
        let chosen = try PumpProfileRules.sessionCookie(in: cookies)
        #expect(chosen.domain == ".pump.fun")
        #expect(chosen.name == "auth_token")
    }
    @Test func rejectsWrongCookieScope() {
        for domain in ["pump.fun", ".fun", ".pump.fun.evil.example", ".evilpump.fun", ".fomo.family"] {
            #expect(throws: PumpReadError.self) { try PumpProfileRules.sessionCookie(in: [cookie(domain: domain)]) }
        }
        #expect(throws: PumpReadError.self) { try PumpProfileRules.sessionCookie(in: [cookie(path: "/auth/my")]) }
        #expect(throws: PumpReadError.self) { try PumpProfileRules.sessionCookie(in: [cookie(expired: true)]) }
    }
    @Test func rejectsMissingOrAmbiguousSessions() {
        #expect(throws: PumpReadError.self) { try PumpProfileRules.sessionCookie(in: []) }
        #expect(throws: PumpReadError.self) {
            try PumpProfileRules.sessionCookie(in: [cookie(), cookie(domain: "frontend-api-v3.pump.fun")])
        }
    }
    @Test func identityCannotChangeRequestDestination() throws {
        let valid = try PumpProfileRules.userURL(for: PumpSessionIdentity(address: wallet, userId: nil))
        #expect(valid.host == "frontend-api-v3.pump.fun")
        #expect(valid.path == "/users/" + wallet)
        for invalid in ["../auth/logout", "https://example.com", "0xabc", "", "11111?x=1"] {
            #expect(throws: PumpReadError.self) {
                try PumpProfileRules.userURL(for: PumpSessionIdentity(address: invalid, userId: nil))
            }
        }
    }
    @Test func rejectsDifferentProfileIdentity() {
        let identity = PumpSessionIdentity(address: wallet, userId: "account-a")
        #expect(throws: PumpReadError.self) {
            try PumpProfileRules.profile(identity: identity, row: PumpUserRow(address: wallet, userId: "account-b", username: "Other", profile_image: nil))
        }
        #expect(throws: PumpReadError.self) {
            try PumpProfileRules.profile(identity: identity, row: PumpUserRow(address: "other-wallet", userId: "account-a", username: "Other", profile_image: nil))
        }
    }
    @Test func profileSupportsMissingOptionalFieldsAndRestrictsImageHosts() throws {
        let identity = PumpSessionIdentity(address: wallet, userId: nil)
        for image in [nil, "http://images.pump.fun/test.png", "https://pump.fun.evil.example/test.png", "https://user:password@pump.fun/test.png", "https://127.0.0.1/test.png"] as [String?] {
            let result = try PumpProfileRules.profile(identity: identity, row: PumpUserRow(address: wallet, userId: nil, username: nil, profile_image: image))
            #expect(result.avatarURL == nil)
            #expect(result.username == nil)
        }
        let result = try PumpProfileRules.profile(identity: identity, row: PumpUserRow(address: wallet, userId: nil, username: "example", profile_image: "https://imagedelivery.net/avatar/public"))
        #expect(result.avatarURL?.host == "imagedelivery.net")
    }
    @Test func decodesOnlyNeededProfileFields() throws {
        let data = Data("{\"address\":\"\(wallet)\",\"username\":\"example\",\"profile_image\":null,\"bio\":\"ignored\",\"followers\":12}".utf8)
        let row = try JSONDecoder().decode(PumpUserRow.self, from: data)
        #expect(row.username == "example")
        #expect(row.userId == nil)
    }
}
