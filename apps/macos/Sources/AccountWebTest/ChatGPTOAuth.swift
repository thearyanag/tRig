import Foundation
import CryptoKit
import Security
import Network

struct ChatGPTFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum ChatGPTOAuth {
    static let issuer = "https://auth.openai.com"
    static let authorize = URL(string: issuer + "/api/accounts/authorize")!
    static let token = URL(string: issuer + "/api/accounts/oauth/token")!
    static let revoke = URL(string: issuer + "/api/accounts/oauth/revoke")!
    static let jwks = URL(string: issuer + "/.well-known/jwks.json")!
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static func base64url(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decode(_ string: String) -> Data? {
        let base = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatGPTFailure(message: "Could not generate secure sign-in state.") }
        return base64url(Data(bytes))
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.keys.sorted().map { key in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    struct Callback: Sendable { let code: String; let clientID: String }
    static func parseCallback(_ target: String, state: String, existingClientID: String?) throws -> Callback {
        guard let c = URLComponents(string: "http://127.0.0.1" + target), c.path == "/auth/callback" else { throw ChatGPTFailure(message: "Invalid callback path.") }
        let items = c.queryItems ?? []
        func one(_ name: String) throws -> String? {
            let matches = items.filter { $0.name == name }
            guard matches.count <= 1 else { throw ChatGPTFailure(message: "Duplicate callback parameter.") }
            return matches.first?.value
        }
        guard try one("state") == state else { throw ChatGPTFailure(message: "Sign-in state did not match. Start again.") }
        if try one("error") != nil { throw ChatGPTFailure(message: "ChatGPT sign-in was declined or could not complete.") }
        guard let code = try one("code"), !code.isEmpty else { throw ChatGPTFailure(message: "No authorization code returned.") }
        let returned = try one("client_id")
        if let existingClientID, let returned, returned != existingClientID { throw ChatGPTFailure(message: "ChatGPT registration changed unexpectedly.") }
        guard let clientID = returned ?? existingClientID, !clientID.isEmpty, clientID != "dynamic_agent_client" else {
            throw ChatGPTFailure(message: "ChatGPT did not return an issued client ID.")
        }
        return Callback(code: code, clientID: clientID)
    }
    struct Identity: Sendable { let subject: String; let email: String? }
    static func validateIDToken(_ token: String, keys: Data, clientID: String, nonce: String?, now: Date = Date()) throws -> Identity {
        func invalid() -> ChatGPTFailure { ChatGPTFailure(message: "ChatGPT identity verification failed. Please sign in again.") }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = decode(parts[0]), let payload = decode(parts[1]), let signature = decode(parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any], header["alg"] as? String == "RS256",
              let kid = header["kid"] as? String, let jwks = try JSONSerialization.jsonObject(with: keys) as? [String: Any],
              let all = jwks["keys"] as? [[String: Any]],
              let jwk = all.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" && ($0["use"] as? String ?? "sig") == "sig" }),
              let n = (jwk["n"] as? String).flatMap(decode), let e = (jwk["e"] as? String).flatMap(decode) else { throw invalid() }
        func der(_ tag: UInt8, _ data: Data) -> Data {
            var length = data.count
            var len: [UInt8] = []
            if length < 128 { len = [UInt8(length)] }
            else { while length > 0 { len.insert(UInt8(length & 255), at: 0); length >>= 8 }; len.insert(0x80 | UInt8(len.count), at: 0) }
            return Data([tag] + len) + data
        }
        func integer(_ bytes: Data) -> Data {
            var bytes = bytes
            while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
            if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
            return der(0x02, bytes)
        }
        let keyData = der(0x30, integer(n) + integer(e))
        guard let key = SecKeyCreateWithData(keyData as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              claims["iss"] as? String == issuer, let sub = claims["sub"] as? String, !sub.isEmpty,
              let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970 - 5,
              let iat = claims["iat"] as? Double, iat <= now.timeIntervalSince1970 + 5 else { throw invalid() }
        let audience = claims["aud"] as? [String] ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audience.contains(clientID), audience.count <= 1 || claims["azp"] as? String == clientID,
              nonce == nil || claims["nonce"] as? String == nonce else { throw invalid() }
        if let nbf = claims["nbf"] as? Double, nbf > now.timeIntervalSince1970 + 5 { throw invalid() }
        return Identity(subject: sub, email: claims["email"] as? String)
    }
}

// This server receives only a short-lived OAuth callback, never a model prompt or service cookie.
@MainActor
final class ChatGPTLoopback {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<ChatGPTOAuth.Callback, Error>?
    private var outcome: Result<ChatGPTOAuth.Callback, Error>?
    private var timeout: Task<Void, Never>?
    private var state = ""
    private var clientID: String?
    private var host = ""
    func start(state: String, clientID: String?) async throws -> URL {
        self.state = state; self.clientID = clientID
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
        listener.stateUpdateHandler = { [weak self] status in Task { @MainActor in
            guard let self else { return }
            switch status {
            case .ready:
                guard let port = listener.port else { return }
                self.host = "127.0.0.1:\(port.rawValue)"
                self.startContinuation?.resume(returning: URL(string: "http://\(self.host)/auth/callback")!)
                self.startContinuation = nil
            case .failed:
                self.cancel(message: "Could not start the local ChatGPT callback listener.")
            default: break
            }
        } }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            if !Task.isCancelled { self?.cancel(message: "ChatGPT sign-in timed out. Try again.") }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.start(queue: .main)
        }
    }
    func wait() async throws -> ChatGPTOAuth.Callback {
        if let outcome { return try outcome.get() }
        return try await withCheckedThrowingContinuation { callbackContinuation = $0 }
    }
    func cancel(message: String = "Sign-in cancelled.") {
        let error = ChatGPTFailure(message: message)
        startContinuation?.resume(throwing: error); startContinuation = nil
        finish(.failure(error))
        connections.forEach { $0.cancel() }; connections = []
    }
    private func finish(_ result: Result<ChatGPTOAuth.Callback, Error>) {
        guard outcome == nil else { return }
        outcome = result; callbackContinuation?.resume(with: result); callbackContinuation = nil
        timeout?.cancel(); timeout = nil; listener?.cancel(); listener = nil
    }
    private func accept(_ connection: NWConnection) {
        guard outcome == nil, connections.count < 8 else { connection.cancel(); return }
        connections.append(connection)
        connection.start(queue: .main)
        receive(connection, accumulated: Data())
        Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(10))
            guard let connection else { return }
            connection.cancel(); self?.connections.removeAll { $0 === connection }
        }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in Task { @MainActor in
            guard let self else { connection.cancel(); return }
            let buffer = accumulated + (data ?? Data())
            guard buffer.count <= 16384, error == nil else { connection.cancel(); return }
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { self.receive(connection, accumulated: buffer) }; return
            }
            let lines = text.components(separatedBy: "\r\n")
            let request = (lines.first ?? "").split(separator: " ").map(String.init)
            let hostHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }?.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard request.count == 3, request[0] == "GET", hostHeader == self.host,
                  request[1].hasPrefix("/auth/callback?") else { self.respond(connection, ok: false); return }
            do {
                let callback = try ChatGPTOAuth.parseCallback(request[1], state: self.state, existingClientID: self.clientID)
                self.respond(connection, ok: true)
                self.finish(.success(callback))
            } catch {
                self.respond(connection, ok: false)
                // Reject unrelated requests without consuming the pending sign-in.
                let c = URLComponents(string: "http://127.0.0.1" + request[1])
                if c?.queryItems?.filter({ $0.name == "state" }).map(\.value) == [self.state] { self.finish(.failure(error)) }
            }
        } }
    }
    private func respond(_ connection: NWConnection, ok: Bool) {
        let body = ok ? "Return to tRig to finish connecting ChatGPT." : "Invalid sign-in callback. Return to the app and try again."
        let response = "HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
