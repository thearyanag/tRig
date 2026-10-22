import Foundation
import Testing
@testable import AccountWebTest

struct PumpCalloutTests {
    let mint = "pumpCmXqMfrsAkQ5r49WcJnRayYRqmXz6ae8H7H9Dfn"
    let id = "11111111-1111-4111-8111-111111111111"
    @Test func supportedLinksMapToFixedAPITargets() throws {
        #expect(try CalloutInput.parse(mint) == .coin(mint))
        #expect(try CalloutInput.parse("https://pump.fun/coin/\(mint)") == .coin(mint))
        #expect(try CalloutInput.parse("https://pump.fun/coin/\(mint)?highlight_callout=\(id)") == .callout(id))
        #expect(try CalloutInput.parse("https://pump.fun/callouts/\(mint)/\(id)") == .callout(id))
        #expect(try CalloutInput.parse(id) == .callout(id))
    }
    @Test func rejectsForeignHostsPathsAndInvalidIDs() {
        for value in ["https://pump.fun.evil.example/coin/\(mint)", "https://user@pump.fun/coin/\(mint)",
                      "https://pump.fun:3000/coin/\(mint)", "http://pump.fun/coin/\(mint)",
                      "https://pump.fun/coin/\(mint)?highlight_callout=../../auth/logout", "../auth/logout"] {
            #expect(throws: CalloutFailure.self) { try CalloutInput.parse(value) }
        }
        #expect(throws: CalloutFailure.self) { try CalloutInput.mint(id) }
    }
    @Test func textLimitsMatchJavaScriptUTF16AndPreserveExactContent() throws {
        try CalloutInput.validateText(String(repeating: "😀", count: 1000))
        #expect(throws: CalloutFailure.self) { try CalloutInput.validateText(String(repeating: "😀", count: 1001)) }
        #expect(throws: CalloutFailure.self) { try CalloutInput.validateText(" \n\t") }
        let exact = "A test\nwith a second line and literal $values."
        let body = String(decoding: try CalloutInput.multipart(mint: mint, text: exact, boundary: "fixture-boundary"), as: UTF8.self)
        #expect(body.contains("name=\"thesis\"\r\n\r\n" + exact + "\r\n"))
        #expect(body.contains("name=\"chainId\"\r\n\r\n1399811149\r\n"))
        #expect(body.hasSuffix("--fixture-boundary--\r\n"))
    }
    @Test func unknownEligibilityNeverEnablesPublishing() throws {
        for verdict in ["UNKNOWN", "INSUFFICIENT_BALANCE", "EXISTING_CALLOUT", "FUTURE_VERDICT"] {
            let data = Data("{\"eligible\":true,\"preflight\":{\"userFound\":true,\"create\":{\"verdict\":\"\(verdict)\"}}}".utf8)
            #expect(try !JSONDecoder().decode(CalloutEligibility.self, from: data).canPost)
        }
        let data = Data("{\"eligible\":true,\"preflight\":{\"userFound\":true,\"create\":{\"verdict\":\"ELIGIBLE\"}}}".utf8)
        #expect(try JSONDecoder().decode(CalloutEligibility.self, from: data).canPost)
    }
    @Test func duplicateKeyIsStableAndBoundToAccountCoinAndExactText() {
        let a = CalloutDraft(mint: mint, text: "test", wallet: "a", username: "name")
        let b = CalloutDraft(mint: mint, text: "test", wallet: "a", username: "renamed")
        let c = CalloutDraft(mint: mint, text: "test", wallet: "b", username: "name")
        let d = CalloutDraft(mint: mint, text: "test\n", wallet: "a", username: "name")
        #expect(a.attemptKey == b.attemptKey)
        #expect(a.attemptKey != c.attemptKey)
        #expect(a.attemptKey != d.attemptKey)
        #expect(!a.attemptKey.contains("test"))
    }
    @Test func cookiePathIsCheckedForEachDestination() throws {
        let cookie = HTTPCookie(properties: [.name: "auth_token", .value: "synthetic-test", .domain: ".pump.fun", .path: "/auth"])!
        #expect(try PumpProfileRules.sessionCookie(in: [cookie]).path == "/auth")
        #expect(throws: PumpReadError.self) {
            try PumpProfileRules.sessionCookie(in: [cookie], for: PumpProfileRules.api.appendingPathComponent("callout/create"))
        }
        #expect(throws: PumpReadError.self) {
            try PumpProfileRules.sessionCookie(in: [cookie], for: URL(string: "https://evil.example/auth/my-profile")!)
        }
    }
}
