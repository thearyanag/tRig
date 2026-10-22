import Foundation
import Security
import Testing
@testable import AccountWebTest

struct ChatGPTTests {
    @Test func callbackBindsStateAndRegistration() throws {
        let callback = try ChatGPTOAuth.parseCallback("/auth/callback?state=expected&code=synthetic&client_id=oaiapp_test", state: "expected", existingClientID: nil)
        #expect(callback.clientID == "oaiapp_test")
        #expect(throws: ChatGPTFailure.self) { try ChatGPTOAuth.parseCallback("/auth/callback?state=wrong&code=synthetic&client_id=oaiapp_test", state: "expected", existingClientID: nil) }
        #expect(throws: ChatGPTFailure.self) { try ChatGPTOAuth.parseCallback("/auth/callback?state=expected&state=expected&code=synthetic&client_id=oaiapp_test", state: "expected", existingClientID: nil) }
        #expect(throws: ChatGPTFailure.self) { try ChatGPTOAuth.parseCallback("/auth/callback?state=expected&code=synthetic&client_id=oaiapp_other", state: "expected", existingClientID: "oaiapp_test") }
        #expect(throws: ChatGPTFailure.self) { try ChatGPTOAuth.parseCallback("/auth/callback?state=expected&code=synthetic&client_id=dynamic_agent_client", state: "expected", existingClientID: nil) }
        #expect(throws: ChatGPTFailure.self) { try ChatGPTOAuth.parseCallback("/auth/callback?state=expected&error=access_denied", state: "expected", existingClientID: nil) }
        #expect(try ChatGPTOAuth.parseCallback("/auth/callback?state=expected&code=synthetic", state: "expected", existingClientID: "oaiapp_test").clientID == "oaiapp_test")
    }
    @Test func formEncodingDoesNotChangeOAuthValues() {
        let form = String(decoding: ChatGPTOAuth.form(["code": "a+b/c= &value", "scope": "openid email"]), as: UTF8.self)
        #expect(form == "code=a%2Bb%2Fc%3D%20%26value&scope=openid%20email")
        #expect(ChatGPTOAuth.decode(ChatGPTOAuth.base64url(Data([0, 255, 1]))) == Data([0, 255, 1]))
    }
    @Test func streamRequiresCompletionAndRejectsFailuresAfterDeltas() throws {
        var stream = ChatGPTStream()
        #expect(try stream.consume("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}") == "Hello")
        #expect(!stream.completed)
        #expect(throws: ChatGPTFailure.self) { try stream.consume("data: {\"type\":\"response.failed\"}") }
        #expect(!stream.completed)
        var completed = ChatGPTStream()
        _ = try completed.consume("data: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"Done\"}]}]}}")
        #expect(completed.completed && completed.text == "Done")
        var incomplete = ChatGPTStream()
        #expect(throws: ChatGPTFailure.self) { try incomplete.consume("data: {\"type\":\"response.incomplete\"}") }
    }
    @Test func planPermissionIsRequired() {
        var profile = ChatGPTProfile(id: UUID(), clientID: "oaiapp_test", subject: "test", accessToken: "synthetic")
        #expect(!profile.sharing)
        profile.scopes = ["chatgpt.tokens.use.direct"]
        #expect(profile.sharing)
        profile.accessToken = nil
        #expect(!profile.sharing)
    }

    // Locally generated synthetic signing key; no real authentication material is read by these tests.
    @Test func identityVerificationChecksSignatureAndAllBoundClaims() throws {
        let privateKey = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        let bytes = [UInt8](der)
        var index = 0
        func read(_ tag: UInt8) throws -> Data {
            #expect(bytes[index] == tag); index += 1
            var count = Int(bytes[index]); index += 1
            if count & 0x80 != 0 { let n = count & 0x7f; count = 0; for _ in 0..<n { count = count * 256 + Int(bytes[index]); index += 1 } }
            let result = Data(bytes[index..<index+count]); index += count; return result
        }
        #expect(bytes[index] == 0x30); index += 1
        let lengthByte = bytes[index]; index += 1
        if lengthByte & 0x80 != 0 { index += Int(lengthByte & 0x7f) }
        var n = try read(0x02); if n.first == 0 { n.removeFirst() }
        let e = try read(0x02)
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "fixture", "kty": "RSA", "use": "sig", "n": ChatGPTOAuth.base64url(n), "e": ChatGPTOAuth.base64url(e)]]])
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var claims: [String: Any] = ["iss": ChatGPTOAuth.issuer, "aud": "oaiapp_test", "sub": "fixture-user", "exp": now.timeIntervalSince1970 + 60, "iat": now.timeIntervalSince1970, "nonce": "fixture-nonce"]
        func sign(_ claims: [String: Any]) throws -> String {
            let header = ChatGPTOAuth.base64url(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "fixture"]))
            let body = ChatGPTOAuth.base64url(try JSONSerialization.data(withJSONObject: claims))
            let signed = header + "." + body
            let signature = try #require(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData, nil)) as Data
            return signed + "." + ChatGPTOAuth.base64url(signature)
        }
        let valid = try sign(claims)
        #expect(try ChatGPTOAuth.validateIDToken(valid, keys: jwks, clientID: "oaiapp_test", nonce: "fixture-nonce", now: now).subject == "fixture-user")
        #expect(throws: ChatGPTFailure.self) { try ChatGPTOAuth.validateIDToken(valid, keys: jwks, clientID: "other", nonce: "fixture-nonce", now: now) }
        #expect(throws: ChatGPTFailure.self) { try ChatGPTOAuth.validateIDToken(valid, keys: jwks, clientID: "oaiapp_test", nonce: "wrong", now: now) }
        #expect(throws: ChatGPTFailure.self) { try ChatGPTOAuth.validateIDToken(valid, keys: jwks, clientID: "oaiapp_test", nonce: "fixture-nonce", now: now.addingTimeInterval(100)) }
        let pieces = valid.split(separator: ".")
        let tampered = pieces[0] + "." + ChatGPTOAuth.base64url(Data("{}".utf8)) + "." + pieces[2]
        #expect(throws: ChatGPTFailure.self) { try ChatGPTOAuth.validateIDToken(tampered, keys: jwks, clientID: "oaiapp_test", nonce: "fixture-nonce", now: now) }
        claims["iss"] = "https://example.com"
        let wrongIssuer = try sign(claims)
        #expect(throws: ChatGPTFailure.self) { try ChatGPTOAuth.validateIDToken(wrongIssuer, keys: jwks, clientID: "oaiapp_test", nonce: "fixture-nonce", now: now) }
    }
}
