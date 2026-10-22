import Foundation
import SwiftUI

struct PumpSessionIdentity: Decodable, Sendable {
    let address: String
    let userId: String?
}

struct PumpUserRow: Decodable, Sendable {
    let address: String
    let userId: String?
    let username: String?
    let profile_image: String?
}

struct PumpProfile: Sendable {
    let username: String?
    let wallet: String
    let avatarURL: URL?
    let checkedAt: Date
}

enum PumpReadError: LocalizedError {
    case missingSession, ambiguousSession, expiredSession, http(Int), unexpectedResponse, changedSession
    var errorDescription: String? {
        switch self {
        case .missingSession: "No usable Pump session cookie. Sign in on Pump, then refresh the profile."
        case .ambiguousSession: "Multiple Pump session cookies matched. Open Pump and sign in again before retrying."
        case .expiredSession: "Pump rejected this session. Refresh the website or sign in again, then retry."
        case .http(let code): "Pump returned HTTP \(code). No automatic retries were sent."
        case .unexpectedResponse: "Pump returned an unexpected profile response."
        case .changedSession: "The session changed during this read. Refresh to load the current account."
        }
    }
}

enum PumpProfileRules {
    static let api = URL(string: "https://frontend-api-v3.pump.fun")!
    static let identityURL = api.appendingPathComponent("auth/my-profile")

    static func sessionCookie(in cookies: [HTTPCookie], for destination: URL = identityURL, now: Date = Date()) throws -> HTTPCookie {
        guard destination.scheme == "https", destination.host == api.host, destination.port == nil,
              destination.user == nil, destination.password == nil else { throw PumpReadError.missingSession }
        let candidates = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let hostMatches = domain.hasPrefix(".")
                ? identityURL.host! == String(domain.dropFirst()) || identityURL.host!.hasSuffix(domain)
                : identityURL.host! == domain
            let requestPath = destination.path
            let pathMatches = requestPath == cookie.path ||
                (requestPath.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || requestPath.dropFirst(cookie.path.count).hasPrefix("/")))
            return [".pump.fun", ".frontend-api-v3.pump.fun", "frontend-api-v3.pump.fun"].contains(domain) &&
                cookie.name == "auth_token" && hostMatches && pathMatches &&
                (cookie.expiresDate.map { $0 > now } ?? true) && !cookie.value.isEmpty
        }
        guard !candidates.isEmpty else { throw PumpReadError.missingSession }
        guard candidates.count == 1 else { throw PumpReadError.ambiguousSession }
        return candidates[0]
    }

    static func userURL(for identity: PumpSessionIdentity) throws -> URL {
        guard identity.address.range(of: "^[1-9A-HJ-NP-Za-km-z]{32,44}$", options: .regularExpression) != nil else {
            throw PumpReadError.unexpectedResponse
        }
        // Resolve by the session's wallet so UUID/alias paths cannot change the request destination.
        return api.appendingPathComponent("users").appendingPathComponent(identity.address)
    }

    static func profile(identity: PumpSessionIdentity, row: PumpUserRow) throws -> PumpProfile {
        guard row.address == identity.address,
              identity.userId == nil || row.userId == nil || identity.userId == row.userId else {
            throw PumpReadError.unexpectedResponse
        }
        let avatar = row.profile_image.flatMap(URL.init(string:)).flatMap { url -> URL? in
            guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else { return nil }
            let host = url.host?.lowercased() ?? ""
            // Public image hosts only; no session cookie is attached to image requests.
            guard host == "pump.fun" || host.hasSuffix(".pump.fun") || host == "imagedelivery.net" ||
                  host == "ipfs.io" || host == "gateway.pinata.cloud" || host == "pump.mypinata.cloud" else { return nil }
            return url
        }
        return PumpProfile(username: row.username, wallet: identity.address, avatarURL: avatar, checkedAt: Date())
    }
}

final class NoProfileRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

struct PumpProfileClient {
    func load(cookie: HTTPCookie) async throws -> PumpProfile {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: NoProfileRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: PumpProfileRules.identityURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Only this one read sends the selected Pump cookie, only to the fixed Pump API endpoint.
        request.setValue(HTTPCookie.requestHeaderFields(with: [cookie])["Cookie"], forHTTPHeaderField: "Cookie")
        let identity: PumpSessionIdentity = try await read(request, session: session)
        try Task.checkCancellation()
        var publicRequest = URLRequest(url: try PumpProfileRules.userURL(for: identity), cachePolicy: .reloadIgnoringLocalCacheData)
        publicRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let row: PumpUserRow = try await read(publicRequest, session: session)
        return try PumpProfileRules.profile(identity: identity, row: row)
    }

    private func read<T: Decodable>(_ request: URLRequest, session: URLSession) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PumpReadError.unexpectedResponse }
        if http.statusCode == 401 { throw PumpReadError.expiredSession }
        guard (200..<300).contains(http.statusCode) else { throw PumpReadError.http(http.statusCode) }
        guard data.count <= 1_000_000 else { throw PumpReadError.unexpectedResponse }
        guard let result = try? JSONDecoder().decode(T.self, from: data) else { throw PumpReadError.unexpectedResponse }
        return result
    }
}

struct PumpProfilePanel: View {
    @ObservedObject var session: BrowserSession
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Native Pump profile", systemImage: "person.crop.rectangle")
                    .font(.headline)
                Spacer()
                if session.profileLoading { ProgressView().controlSize(.small) }
            }
            if let profile = session.pumpProfile {
                HStack(spacing: 12) {
                    AsyncImage(url: profile.avatarURL) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary) }
                    }.frame(width: 56, height: 56).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.username ?? "No username set").font(.title3.bold()).textSelection(.enabled)
                        Text("Session verified at read time").font(.caption).foregroundStyle(.green)
                    }
                }
                Text("SESSION WALLET").font(.caption2).foregroundStyle(.secondary)
                Text(profile.wallet).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("Read at \(profile.checkedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Load the profile for the account signed in on Pump.").foregroundStyle(.secondary)
            }
            if let error = session.profileError { Text(error).font(.callout).foregroundStyle(.orange) }
            Button(session.profileLoading ? "Reading…" : "Refresh Profile") { session.readPumpProfile() }
                .disabled(session.profileLoading || session.webView.url?.host != "pump.fun")
            Text("Native HTTPS reads · No trading\nProfile details are a snapshot; refresh after changing accounts.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(16).frame(width: 286).frame(maxHeight: .infinity, alignment: .top)
    }
}
