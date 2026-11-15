import Foundation

public struct SupabaseConfiguration: Sendable {
    public let url: URL
    public let publishableKey: String

    /// This client accepts only public publishable keys, never a service role,
    /// secret key, password, or an arbitrary JWT copied from a dashboard.
    public init(url: URL, publishableKey: String) throws {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              publishableKey.hasPrefix("sb_publishable_"),
              !publishableKey.contains(where: { $0.isWhitespace }) else {
            throw AuthenticationFailure.invalidResponse
        }
        self.url = url
        self.publishableKey = publishableKey
    }
}

extension SupabaseConfiguration {
    static func makeEphemeralSession(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let network = URLSessionConfiguration.ephemeral
        network.httpCookieStorage = nil
        network.urlCache = nil
        network.timeoutIntervalForRequest = requestTimeout
        network.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: network)
    }

    func jsonPost(to endpoint: URL, body: Data, accessToken: String?) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        return request
    }
}

/// The small Auth REST surface deliberately has no signup, account mutation,
/// provider credentials, or project configuration endpoints.
public struct SupabaseAuthenticationClient: AuthenticationClient, BetaAccountApproval {
    private let configuration: SupabaseConfiguration
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(configuration: SupabaseConfiguration, session: URLSession? = nil,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.configuration = configuration
        self.session = session ?? SupabaseConfiguration.makeEphemeralSession(requestTimeout: 20, resourceTimeout: 30)
        self.now = now
    }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        try await token(grant: "password", body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password])
    }

    public func refresh(refreshToken: String) async throws -> AuthSession {
        try await token(grant: "refresh_token", body: ["refresh_token": refreshToken])
    }

    public func isApproved(accessToken: String) async throws -> Bool {
        let endpoint = configuration.url.appendingPathComponent("rest/v1/rpc/bitelens_is_approved")
        let request = configuration.jsonPost(to: endpoint, body: Data("{}".utf8), accessToken: accessToken)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthenticationFailure.unavailable
        }
        return try JSONDecoder().decode(Bool.self, from: data)
    }

    public func signOut(accessToken: String) async throws {
        // Revoke this app's session only, preserving the owner's other apps.
        _ = try await request(path: "logout", query: [URLQueryItem(name: "scope", value: "local")], body: [:], bearer: accessToken)
    }

    private func token(grant: String, body: [String: String]) async throws -> AuthSession {
        let data: Data
        do { data = try await request(path: "token", query: [URLQueryItem(name: "grant_type", value: grant)], body: body) }
        catch AuthenticationFailure.invalidCredentials where grant == "refresh_token" {
            throw AuthenticationFailure.sessionExpired
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !token.access_token.isEmpty, !token.refresh_token.isEmpty,
              token.expires_in.isFinite, token.expires_in >= 0 else {
            throw AuthenticationFailure.invalidResponse
        }
        // Identity comes from the Auth server's response, never user_metadata.
        return AuthSession(userID: token.user.id, accessToken: token.access_token,
                           refreshToken: token.refresh_token, expiresAt: now().addingTimeInterval(token.expires_in))
    }

    private func request(path: String, query: [URLQueryItem], body: [String: String], bearer: String? = nil) async throws -> Data {
        var components = URLComponents(url: configuration.url.appendingPathComponent("auth/v1/\(path)"), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        let request = configuration.jsonPost(to: components.url!, body: try JSONEncoder().encode(body), accessToken: bearer)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw AuthenticationFailure.unavailable }
        guard let http = response as? HTTPURLResponse else { throw AuthenticationFailure.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 400, 401, 403: throw AuthenticationFailure.invalidCredentials
        default: throw AuthenticationFailure.unavailable
        }
        // Never surface raw response bodies (which can contain sensitive data).
    }
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: TimeInterval
    let user: User
    struct User: Decodable { let id: UUID }
}
