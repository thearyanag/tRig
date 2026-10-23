import SwiftUI
import WebKit
import CryptoKit

struct FomoFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct FomoProfile {
    let id: String
    let handle: String
    let displayName: String
    let avatar: URL?
    let address: String?
}

struct FomoTrade: Identifiable {
    let id: String
    let token: String
    let symbol: String
    let wallet: String
    let closed: Bool
    let comment: String?
}
struct FomoThesis: Identifiable {
    let id: String
    let author: String
    let text: String
}
struct FomoDraft: Identifiable {
    let id = UUID()
    let trade: FomoTrade
    let profile: FomoProfile
    let text: String
    let sessionFingerprint: String
    var attemptKey: String {
        let data = try! JSONEncoder().encode([profile.id, trade.id, text])
        return "fomo.thesis.attempt." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum FomoRules {
    static let api = URL(string: "https://prod-api.fomo.family")!
    static func handle(_ value: String) throws -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("https://") {
            guard let url = URLComponents(string: value), url.host == "fomo.family", url.port == nil,
                  url.user == nil, url.password == nil, url.path.hasPrefix("/profile/") else { throw FomoFailure(message: "Use a Fomo profile handle or profile URL.") }
            value = String(url.path.dropFirst("/profile/".count))
        }
        guard value.range(of: "^[A-Za-z0-9_]{1,64}$", options: .regularExpression) != nil else { throw FomoFailure(message: "Invalid Fomo handle.") }
        return value
    }
    static func trade(_ row: [String: Any]) -> FomoTrade? {
        guard let trade = row["trade"] as? [String: Any], let id = trade["id"] as? String, UUID(uuidString: id) != nil,
              let token = trade["tokenAddress"] as? String, let wallet = trade["userAddress"] as? String else { return nil }
        let meta = trade["tokenMetadata"] as? [String: Any]
        let comment = row["comment"] as? [String: Any]
        return FomoTrade(id: id, token: token, symbol: meta?["symbol"] as? String ?? String(token.prefix(8)), wallet: wallet,
                         closed: trade["closedAt"] != nil && !(trade["closedAt"] is NSNull), comment: comment?["comment"] as? String)
    }
    static func thesis(_ row: [String: Any]) -> FomoThesis? {
        let comment = row["comment"] as? [String: Any] ?? row["thesis"] as? [String: Any] ?? row
        guard let text = comment["comment"] as? String, let id = comment["id"] as? String ?? row["commentId"] as? String else { return nil }
        return FomoThesis(id: id, author: row["userHandle"] as? String ?? comment["userHandle"] as? String ?? comment["userId"] as? String ?? "Fomo user", text: text)
    }
    static func validateDraft(trade: FomoTrade, profile: FomoProfile, text: String) throws {
        guard UUID(uuidString: trade.id) != nil, CalloutInput.isMint(trade.token), trade.wallet == profile.address else {
            throw FomoFailure(message: "Select one of this profile's Solana trades. No purchase is needed.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 1000 else {
            throw FomoFailure(message: "Enter 1–1000 characters for this test post.")
        }
    }
    static func sessionFingerprint(_ cookies: [HTTPCookie]) throws -> String {
        let data = try JSONEncoder().encode(cookies.sorted { $0.name < $1.name }.map { [$0.name, $0.value] })
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func retryDate(_ value: String, now: Date = Date()) -> Date? {
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    static func cookies(_ cookies: [HTTPCookie], url: URL, now: Date = Date()) throws -> [HTTPCookie] {
        guard url.scheme == "https", url.host == api.host, url.port == nil, url.user == nil, url.password == nil else { throw FomoFailure(message: "Invalid API destination.") }
        let allowed = Set(["privy-token", "privy-id-token", "privy-session"])
        let selected = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let path = url.path.isEmpty ? "/" : url.path
            return allowed.contains(cookie.name) && [".fomo.family", ".prod-api.fomo.family", "prod-api.fomo.family"].contains(domain) &&
                (cookie.expiresDate.map { $0 > now } ?? true) && !cookie.value.isEmpty &&
                (path == cookie.path || (path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/"))))
        }
        guard !selected.isEmpty, Set(selected.map(\.name)).count == selected.count else { throw FomoFailure(message: "No unambiguous Fomo session cookies. Open Fomo and refresh its login first.") }
        return selected
    }
}

@MainActor
final class FomoNativeModel: ObservableObject {
    @Published var handle = ""
    @Published var profile: FomoProfile?
    @Published var status = "Use your Fomo session to read this profile."
    @Published var rateInfo = "No native request yet."
    @Published var diagnostics = ""
    @Published var busy = false
    @Published var trades: [FomoTrade] = []
    @Published var theses: [FomoThesis] = []
    @Published var thesisSource = ""
    @Published var selectedTrade = ""
    @Published var tokenInput = "pumpCmXqMfrsAkQ5r49WcJnRayYRqmXz6ae8H7H9Dfn"
    @Published var postText = ""
    @Published var draft: FomoDraft?
    private var blockedUntil: Date?
    private var readSessionFingerprint: String?

    func fingerprint() async throws -> String {
        let cookies = try FomoRules.cookies(await store.allCookies(), url: FomoRules.api.appendingPathComponent("trades/comment"))
        return try FomoRules.sessionFingerprint(cookies)
    }
    let store: WKHTTPCookieStore
    init(store: WKHTTPCookieStore) { self.store = store }

    func get(_ path: [String], query: [URLQueryItem] = [], postBody: Data? = nil, expectedSession: String? = nil) async throws -> Any {
        if let until = blockedUntil, until > Date() {
            throw FomoFailure(message: "Fomo requested a cooldown. Retry after \(until.formatted(date: .omitted, time: .standard)).")
        }
        if postBody != nil && path != ["trades", "comment"] { throw FomoFailure(message: "Unsupported write endpoint.") }
        let base = path.reduce(FomoRules.api) { $0.appendingPathComponent($1) }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        let url = components.url!
        let cookies = await store.allCookies()
        let scoped = try FomoRules.cookies(cookies, url: url)
        if let expectedSession, try FomoRules.sessionFingerprint(scoped) != expectedSession {
            throw FomoFailure(message: "Session changed before dispatch. No post sent; review again.")
        }
        diagnostics = "Scoped cookie names: " + scoped.map(\.name).sorted().joined(separator: ", ")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: NoProfileRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let postBody {
            request.httpMethod = "POST"
            request.httpBody = postBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("en", forHTTPHeaderField: "App-Language")
        request.setValue(HTTPCookie.requestHeaderFields(with: scoped)["Cookie"], forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FomoFailure(message: "No HTTP response.") }
        let keys = ["X-RateLimit-Limit", "X-RateLimit-Remaining", "X-RateLimit-Reset", "RateLimit-Limit", "RateLimit-Remaining", "RateLimit-Reset", "Retry-After"]
        let hints = keys.compactMap { key in http.value(forHTTPHeaderField: key).map { "\(key): \($0)" } }
        rateInfo = "HTTP \(http.statusCode) · " + (hints.isEmpty ? "No rate-limit headers returned." : hints.joined(separator: " · "))
        if let hint = http.value(forHTTPHeaderField: "Retry-After"), let until = FomoRules.retryDate(hint), until > Date() { blockedUntil = until }
        guard (200..<300).contains(http.statusCode) else { throw FomoFailure(message: "Fomo returned HTTP \(http.statusCode). No retries sent.") }
        guard data.count < 5_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FomoFailure(message: "Unexpected API response.") }
        guard object["success"] as? Bool == true, let result = object["responseObject"] else {
            let code = object["errorCode"] as? String ?? ""
            let safeCode = code.range(of: "^[A-Z_]{1,80}$", options: .regularExpression) != nil ? " · " + code : ""
            throw FomoFailure(message: "Fomo did not report success (status \(object["statusCode"] as? Int ?? 0)\(safeCode)). No automatic retry.")
        }
        return result
    }
    func readProfile() {
        guard !busy else { return }
        busy = true
        profile = nil
        trades = []
        selectedTrade = ""
        readSessionFingerprint = nil
        Task {
            defer { busy = false }
            do {
                let requested = try FomoRules.handle(handle)
                let before = try await fingerprint()
                guard let row = try await get(["v2", "users", "userHandle", requested]) as? [String: Any],
                      let id = row["id"] as? String, let returned = row["userHandle"] as? String,
                      returned.lowercased() == requested.lowercased() else { throw FomoFailure(message: "Unexpected profile response.") }
                let avatar = (row["profilePictureLink"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
                profile = FomoProfile(id: id, handle: returned, displayName: row["displayName"] as? String ?? returned,
                                      avatar: avatar, address: row["address"] as? String)
                guard try await fingerprint() == before else { profile = nil; throw FomoFailure(message: "Session changed. Read the profile again.") }
                readSessionFingerprint = before
                status = "Native profile read succeeded for @\(returned)."
                diagnostics += "\nProfile fields: " + row.keys.sorted().joined(separator: ", ")
            } catch { status = (error as? FomoFailure)?.message ?? "Profile request failed. Try again after checking the website." }
        }
    }
    func errorMessage(_ error: Error) -> String {
        (error as? FomoFailure)?.message ?? "The native request could not complete."
    }
    func readTheses() {
        guard !busy, let profile else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                guard let result = try await get(["trades"], query: [.init(name: "userId", value: profile.id), .init(name: "orderBy", value: "closedAt")]) as? [String: Any] else { throw FomoFailure(message: "Unexpected trade response.") }
                let rows = (result["activeTrades"] as? [[String: Any]] ?? []) + (result["closedTrades"] as? [[String: Any]] ?? [])
                trades = rows.compactMap(FomoRules.trade)
                selectedTrade = trades.first(where: { !$0.closed && $0.wallet == profile.address })?.id ?? ""
                status = "Read \(trades.count) trades from the first page. Select one to read its theses or prepare a post."
            } catch { status = errorMessage(error) }
        }
    }
    func readFeed() {
        guard !busy else { return }
        busy = true
        theses = []
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { busy = false }
            do {
                guard CalloutInput.isMint(token) else { throw FomoFailure(message: "Enter a Solana token address.") }
                guard let result = try await get(["feed", "token", "thesis"], query: [.init(name: "tokenAddress", value: token), .init(name: "networkId", value: "1399811149")]) as? [String: Any] else { throw FomoFailure(message: "Unexpected thesis feed response.") }
                let items = result["items"] as? [[String: Any]] ?? []
                theses = items.prefix(10).compactMap(FomoRules.thesis)
                thesisSource = "Fomo source: Solana token " + token
                diagnostics = "Feed fields: " + result.keys.sorted().joined(separator: ", ") + "\nFirst item: " + (items.first?.keys.sorted().joined(separator: ", ") ?? "none")
                if let first = items.first {
                    for (key, value) in first { if let dict = value as? [String: Any] { diagnostics += "\n\(key) fields: " + dict.keys.sorted().joined(separator: ", ") } }
                }
                guard items.isEmpty || !theses.isEmpty else { throw FomoFailure(message: "Feed returned items but their thesis format was not recognized.") }
                status = "Read \(theses.count) theses from Fomo."
            } catch { status = errorMessage(error) }
        }
    }
    func readSelectedTrade() {
        guard !busy, UUID(uuidString: selectedTrade) != nil else { return }
        busy = true
        let id = selectedTrade
        Task {
            defer { busy = false }
            do {
                guard let result = try await get(["trades", id, "comments"]) as? [String: Any] else { throw FomoFailure(message: "Unexpected comments response.") }
                let rows = result["comments"] as? [[String: Any]] ?? []
                theses = rows.prefix(10).compactMap(FomoRules.thesis)
                thesisSource = "Fomo source: trade " + id
                status = "Read \(theses.count) theses/comments for the selected trade."
            } catch { status = errorMessage(error) }
        }
    }
    func reviewPost() {
        guard !busy, let profile, let trade = trades.first(where: { $0.id == selectedTrade }) else { return }
        busy = true
        let text = postText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { busy = false }
            do {
                try FomoRules.validateDraft(trade: trade, profile: profile, text: text)
                let current = try await fingerprint()
                guard current == readSessionFingerprint else { throw FomoFailure(message: "Session changed since the profile read. Read your profile again.") }
                guard let detail = try await get(["trades", trade.id]) as? [String: Any], let fresh = FomoRules.trade(detail), fresh.wallet == trade.wallet, fresh.token == trade.token else { throw FomoFailure(message: "Could not verify the selected trade. No post sent.") }
                let prepared = FomoDraft(trade: fresh, profile: profile, text: text, sessionFingerprint: current)
                guard UserDefaults.standard.string(forKey: prepared.attemptKey) == nil else { throw FomoFailure(message: "This draft was already attempted. Read the trade's theses before trying another post.") }
                draft = prepared
                status = "Draft ready for review. Nothing posted."
            } catch { status = errorMessage(error) }
        }
    }
    func publish(_ reviewed: FomoDraft) {
        guard !busy, draft?.id == reviewed.id else { return }
        busy = true
        draft = nil
        Task {
            defer { busy = false }
            var dispatched = false
            do {
                guard try await fingerprint() == reviewed.sessionFingerprint else { throw FomoFailure(message: "Session changed; review again before posting.") }
                try FomoRules.validateDraft(trade: reviewed.trade, profile: reviewed.profile, text: reviewed.text)
                guard UserDefaults.standard.string(forKey: reviewed.attemptKey) == nil else { throw FomoFailure(message: "This exact draft was already attempted.") }
                let body = try JSONEncoder().encode(["tradeId": reviewed.trade.id, "comment": reviewed.text, "visibility": "public"])
                UserDefaults.standard.set("attempted", forKey: reviewed.attemptKey)
                dispatched = true
                guard let posted = try await get(["trades", "comment"], postBody: body, expectedSession: reviewed.sessionFingerprint) as? [String: Any], let id = posted["id"] as? String else { throw FomoFailure(message: "Create response had no comment ID.") }
                UserDefaults.standard.set(id, forKey: reviewed.attemptKey)
                do {
                    guard let result = try await get(["trades", reviewed.trade.id, "comments"]) as? [String: Any],
                          let rows = result["comments"] as? [[String: Any]],
                          rows.contains(where: { ($0["id"] as? String) == id && ($0["userId"] as? String) == reviewed.profile.id && ($0["comment"] as? String) == reviewed.text }) else { throw FomoFailure(message: "Read-back mismatch.") }
                    theses = rows.prefix(10).compactMap(FomoRules.thesis)
                    thesisSource = "Fomo source: trade " + reviewed.trade.id
                    status = "Published and read back. Thesis ID: \(id)"
                } catch { status = "Fomo accepted thesis \(id); read-back is unverified. Read the selected trade again; do not repost." }
            } catch { status = errorMessage(error) + (dispatched ? " Submission was attempted and will not be retried. Check the trade's theses before posting again." : " No post sent.") }
        }
    }

}

struct FomoNativePanel: View {
    @ObservedObject var model: FomoNativeModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Native Fomo test").font(.headline)
                TextField("Fomo profile handle", text: $model.handle).textFieldStyle(.roundedBorder)
                Button("Read Fomo Profile") { model.readProfile() }.disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                if let profile = model.profile {
                    HStack {
                        AsyncImage(url: profile.avatar) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                            else { Image(systemName: "person.crop.circle.fill").resizable() }
                        }.frame(width: 48, height: 48).clipShape(Circle())
                        VStack(alignment: .leading) { Text(profile.displayName).bold(); Text("@" + profile.handle) }
                    }
                    if let address = profile.address { Text(address).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    Button("Load Profile Trades") { model.readTheses() }.disabled(model.busy)
                }
                Divider()
                Text("Read theses").font(.headline)
                TextField("Solana token address", text: $model.tokenInput).textFieldStyle(.roundedBorder)
                Button("Read Token Theses") { model.readFeed() }.disabled(model.busy)
                Text(model.status).font(.callout).textSelection(.enabled)
                ForEach(model.theses) { thesis in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(thesis.author).font(.caption.bold())
                        Text(thesis.text).font(.callout).textSelection(.enabled)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                if !model.trades.isEmpty {
                    Divider()
                    Text("Post a thesis on your trade").font(.headline)
                    Picker("Trade", selection: $model.selectedTrade) {
                        Text("Choose a trade").tag("")
                        ForEach(model.trades) { trade in Text("\(trade.symbol) · \(trade.closed ? "closed" : "open") · \(trade.id.prefix(6))").tag(trade.id) }
                    }
                    Button("Read Selected Trade Theses") { model.readSelectedTrade() }.disabled(model.busy || model.selectedTrade.isEmpty)
                    TextEditor(text: $model.postText).frame(height: 100).border(.quaternary).accessibilityLabel("Fomo thesis text")
                    Text("\(model.postText.utf16.count)/1000 · test composer limit").font(.caption)
                    Button("Review Fomo Post") { model.reviewPost() }.disabled(model.busy || model.selectedTrade.isEmpty)
                    Text("Uses the current Fomo session. Verify the profile matches your signed-in account. No trading or wallet signing.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("Response limits").font(.headline)
                Text(model.rateInfo).font(.caption).textSelection(.enabled)
                DisclosureGroup("Read diagnostics") { Text(model.diagnostics).font(.caption).textSelection(.enabled) }
            }.padding(14)
        }.frame(width: 344)
        .sheet(item: $model.draft) { draft in
            VStack(alignment: .leading, spacing: 14) {
                Text("Publish this Fomo thesis?").font(.title2.bold())
                Text("Expected author: @\(draft.profile.handle)")
                Text("Coin: \(draft.trade.symbol)")
                Text(draft.trade.token).font(.system(.caption, design: .monospaced))
                Text("Trade: \(draft.trade.id)").font(.caption)
                ScrollView { Text(draft.text).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 200)
                Text("This posts publicly using your current Fomo session. It does not place a trade.")
                HStack { Button("Cancel") { model.draft = nil }; Spacer(); Button("Publish Fomo Thesis") { model.publish(draft) } }
            }.padding(24).frame(width: 500)
        }
    }
}
