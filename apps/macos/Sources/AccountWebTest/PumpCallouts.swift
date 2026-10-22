import SwiftUI
import WebKit
import CryptoKit

struct PumpCallout: Decodable, Identifiable, Sendable {
    let calloutId: String
    let coinMint: String
    let userId: String
    let userName: String?
    let user_uuid: String?
    let thesis: String?
    let createdAt: Double
    var id: String { calloutId }
    var link: URL { URL(string: "https://pump.fun/coin/\(coinMint)?highlight_callout=\(calloutId)")! }
}
struct CalloutEnvelope: Decodable { let callout: PumpCallout? }
struct CalloutList: Decodable { let callouts: [PumpCallout] }
struct CalloutEligibility: Decodable {
    struct Preflight: Decodable {
        struct Create: Decodable { let verdict: String }
        let userFound: Bool
        let create: Create
    }
    let eligible: Bool
    let preflight: Preflight
    var canPost: Bool { eligible && preflight.userFound && preflight.create.verdict == "ELIGIBLE" }
}
struct CalloutDraft: Identifiable, Sendable {
    let id = UUID()
    let mint: String
    let text: String
    let wallet: String
    let username: String
    var attemptKey: String {
        let payload = try! JSONEncoder().encode([wallet, mint, text])
        return "pump.callout.attempt." + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}
struct CalloutFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum CalloutInput {
    enum Target: Equatable { case coin(String), callout(String) }
    static func isMint(_ value: String) -> Bool {
        value.range(of: "^[1-9A-HJ-NP-Za-km-z]{32,44}$", options: .regularExpression) != nil
    }
    static func parse(_ input: String) throws -> Target {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: value) != nil { return .callout(value.lowercased()) }
        if isMint(value) { return .coin(value) }
        guard let url = URLComponents(string: value), url.scheme == "https", url.host == "pump.fun",
              url.user == nil, url.password == nil, url.port == nil else {
            throw CalloutFailure(message: "Enter a Pump callout link, callout UUID, or Solana coin address.")
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "callouts", isMint(parts[1]), UUID(uuidString: parts[2]) != nil {
            return .callout(parts[2].lowercased())
        }
        if parts.count == 2, parts[0] == "coin", isMint(parts[1]) {
            if let highlight = url.queryItems?.first(where: { $0.name == "highlight_callout" })?.value {
                guard UUID(uuidString: highlight) != nil else { throw CalloutFailure(message: "Invalid callout ID in link.") }
                return .callout(highlight.lowercased())
            }
            return .coin(parts[1])
        }
        throw CalloutFailure(message: "This test supports Solana coin and callout links only.")
    }
    static func mint(_ input: String) throws -> String {
        guard case .coin(let mint) = try parse(input) else { throw CalloutFailure(message: "Choose a coin address or coin link for the new post.") }
        return mint
    }
    static func validateText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 2000 else {
            throw CalloutFailure(message: "Enter 1–2,000 UTF-16 characters of post text.")
        }
    }
    static func multipart(mint: String, text: String, boundary: String) throws -> Data {
        guard isMint(mint) else { throw CalloutFailure(message: "Invalid Solana coin address.") }
        try validateText(text)
        guard !text.contains(boundary) else { throw CalloutFailure(message: "Please review the draft again.") }
        let fields = [("coinMint", mint), ("thesis", text), ("version", "2"), ("chainId", String(0x536f6c4d))]
        let body = fields.map { "--\(boundary)\r\nContent-Disposition: form-data; name=\"\($0.0)\"\r\n\r\n\($0.1)\r\n" }.joined() + "--\(boundary)--\r\n"
        return Data(body.utf8)
    }
}

struct PumpCalloutClient {
    func request<T: Decodable>(_ parts: [String], cookie: HTTPCookie? = nil,
                               body: Data? = nil, boundary: String? = nil) async throws -> T {
        let url = parts.reduce(PumpProfileRules.api) { $0.appendingPathComponent($1) }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: NoProfileRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie {
            let scoped = try PumpProfileRules.sessionCookie(in: [cookie], for: url)
            request.setValue(HTTPCookie.requestHeaderFields(with: [scoped])["Cookie"], forHTTPHeaderField: "Cookie")
        }
        if let body, let boundary {
            guard parts == ["callout", "create"] else { throw PumpReadError.unexpectedResponse }
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PumpReadError.unexpectedResponse }
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let rawCode = object?["error"] as? String ?? object?["code"] as? String ?? ""
            let safeCode = rawCode.range(of: "^[A-Z_]{1,64}$", options: .regularExpression) != nil ? " (\(rawCode))" : ""
            throw CalloutFailure(message: "Pump returned HTTP \(response.statusCode)\(safeCode).")
        }
        guard data.count < 5_000_000, let result = try? JSONDecoder().decode(T.self, from: data) else {
            throw PumpReadError.unexpectedResponse
        }
        return result
    }
    func read(_ target: CalloutInput.Target) async throws -> [PumpCallout] {
        switch target {
        case .callout(let id):
            let result: CalloutEnvelope = try await request(["callout", id])
            return result.callout.map { [$0] } ?? []
        case .coin(let mint):
            let result: CalloutList = try await request(["callout", "coin", mint])
            return Array(result.callouts.prefix(10))
        }
    }
}

@MainActor
final class PumpCalloutModel: ObservableObject {
    @Published var readInput = ""
    @Published var mintInput = ""
    @Published var text = ""
    @Published var callouts: [PumpCallout] = []
    @Published var status = "Read a public callout, or prepare your own post below."
    @Published var busy = false
    @Published var draft: CalloutDraft?
    private let store: WKHTTPCookieStore
    private let client = PumpCalloutClient()
    init(store: WKHTTPCookieStore) { self.store = store }
    private func cookie() async throws -> HTTPCookie {
        try PumpProfileRules.sessionCookie(in: await store.allCookies())
    }
    private func message(_ error: Error) -> String {
        (error as? CalloutFailure)?.message ?? (error as? PumpReadError)?.errorDescription ?? "Request could not complete. Check the connection."
    }
    func read() {
        guard !busy else { return }
        busy = true
        callouts = []
        let input = readInput
        Task {
            defer { busy = false }
            do {
                callouts = try await client.read(CalloutInput.parse(input))
                status = callouts.isEmpty ? "No callout found." : "Read \(callouts.count) public callout(s) through the native API."
            } catch { status = message(error) }
        }
    }
    func review() {
        guard !busy else { return }
        busy = true
        let mintInput = mintInput, content = text
        Task {
            defer { busy = false }
            do {
                let mint = try CalloutInput.mint(mintInput)
                try CalloutInput.validateText(content)
                let cookie = try await cookie()
                let profile = try await PumpProfileClient().load(cookie: cookie)
                let eligibility: CalloutEligibility = try await client.request(["callout", "eligibility", mint], cookie: cookie)
                guard eligibility.canPost else {
                    throw CalloutFailure(message: "Pump says this account cannot post on this coin: \(eligibility.preflight.create.verdict). No post sent.")
                }
                let prepared = CalloutDraft(mint: mint, text: content, wallet: profile.wallet, username: profile.username ?? profile.wallet)
                guard UserDefaults.standard.string(forKey: prepared.attemptKey) == nil else {
                    throw CalloutFailure(message: "This exact draft was already submitted or attempted. Check its callout before trying anything else; automatic resubmission is blocked.")
                }
                draft = prepared
                status = "Ready for review. Nothing has been published."
            } catch { status = message(error) }
        }
    }
    func publish(_ reviewed: CalloutDraft) {
        guard !busy, draft?.id == reviewed.id else { return }
        busy = true
        draft = nil
        Task {
            defer { busy = false }
            var dispatched = false
            do {
                let cookie = try await cookie()
                let identity: PumpSessionIdentity = try await client.request(["auth", "my-profile"], cookie: cookie)
                guard identity.address == reviewed.wallet else { throw PumpReadError.changedSession }
                let eligibility: CalloutEligibility = try await client.request(["callout", "eligibility", reviewed.mint], cookie: cookie)
                guard eligibility.canPost else { throw CalloutFailure(message: "Eligibility changed: \(eligibility.preflight.create.verdict). No post sent.") }
                guard UserDefaults.standard.string(forKey: reviewed.attemptKey) == nil else {
                    throw CalloutFailure(message: "This draft has already been attempted. No repeat post sent.")
                }
                let boundary = "PumpNative-" + UUID().uuidString
                let body = try CalloutInput.multipart(mint: reviewed.mint, text: reviewed.text, boundary: boundary)
                // Persist the attempt before dispatch. Ambiguous failures must never trigger an automatic retry.
                UserDefaults.standard.set("attempted", forKey: reviewed.attemptKey)
                dispatched = true
                let created: CalloutEnvelope = try await client.request(["callout", "create"], cookie: cookie, body: body, boundary: boundary)
                guard let posted = created.callout, UUID(uuidString: posted.calloutId) != nil else { throw PumpReadError.unexpectedResponse }
                UserDefaults.standard.set(posted.calloutId, forKey: reviewed.attemptKey)
                readInput = posted.link.absoluteString
                status = "Pump accepted the post. Verifying by reading it back…"
                do {
                    let result = try await client.read(.callout(posted.calloutId))
                    guard let fetched = result.first, fetched.coinMint == reviewed.mint,
                          fetched.userId == reviewed.wallet, fetched.thesis == reviewed.text else { throw PumpReadError.unexpectedResponse }
                    callouts = result
                    status = "Published and read back successfully. Callout ID: \(posted.calloutId)"
                } catch {
                    status = "Pump returned callout ID \(posted.calloutId), but read-back is unverified. Use Read to check; do not repost."
                }
            } catch {
                status = message(error) + (dispatched ? " Submission was attempted; it will not be retried. Check Pump before making another post." : " No post sent.")
            }
        }
    }
}

struct PumpCalloutPanel: View {
    @ObservedObject var model: PumpCalloutModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Native callouts").font(.headline)
                TextField("Callout link, UUID, or Solana coin", text: $model.readInput).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Callout to read")
                Button("Read Callout") { model.read() }.disabled(model.busy)
                Text(model.status).font(.caption).textSelection(.enabled)
                if model.busy { ProgressView().controlSize(.small) }
                ForEach(model.callouts) { callout in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(callout.userName ?? callout.userId).font(.headline)
                        Text(callout.thesis ?? "No text").textSelection(.enabled)
                        Text(Date(timeIntervalSince1970: callout.createdAt / 1000), format: .dateTime)
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Coin: \(callout.coinMint)").font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        Link("View on Pump", destination: callout.link).font(.caption)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                Divider()
                Text("New public callout").font(.headline)
                TextField("Solana coin address or Pump coin link", text: $model.mintInput)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Post coin")
                TextEditor(text: $model.text).frame(height: 110).border(.quaternary)
                    .accessibilityLabel("Callout text")
                Text("\(model.text.utf16.count)/2000").font(.caption).foregroundStyle(.secondary)
                Button("Check Eligibility & Review") { model.review() }.disabled(model.busy)
                Text("Posts are public and linked to your Pump account. This test supports text-only Solana callouts. It does not buy coins or sign transactions.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(14)
        }.frame(width: 330)
        .sheet(item: $model.draft) { draft in
            VStack(alignment: .leading, spacing: 14) {
                Text("Publish this public callout?").font(.title2.bold())
                Text("Account: \(draft.username)")
                Text(draft.wallet).font(.system(.caption, design: .monospaced))
                Text("Coin: \(draft.mint)").font(.system(.caption, design: .monospaced))
                ScrollView { Text(draft.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 200).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Text("This posts publicly to Pump. It does not place a trade.").font(.callout)
                HStack {
                    Button("Cancel") { model.draft = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Publish Callout") { model.publish(draft) }
                }
            }.padding(24).frame(width: 500)
        }
    }
}
