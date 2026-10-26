import Foundation

/// Kilimanjaro Gate Swift SDK
///
/// `GateClient` is the primary entry point. Initialise once per project
/// and call `signIn`, `refreshToken`, and `signOut`.
///
/// Refresh tokens are automatically persisted in the iOS/macOS Keychain
/// by default. Pass `tokenStore: nil` to manage token persistence
/// yourself.
///
/// Example:
/// ```swift
/// let gate = GateClient(
///     orgBaseURL: URL(string: "https://acme.api.k9o.io")!,
///     projectSlug: "my-project"
/// )
/// let result = try await gate.signIn(email: "user@example.com", password: "s3cr3t")
/// ```
public struct GateClient: Sendable {
    private let client: GateAuthClient
    private let tokenStore: KeychainTokenStore?

    /// - Parameters:
    ///   - orgBaseURL: The org-scoped API base (e.g. `https://acme.api.k9o.io`).
    ///   - projectSlug: The `@`-addressable project slug (e.g. `my-project`).
    ///   - tokenStore: Keychain token store. Pass `nil` to skip automatic
    ///     refresh-token persistence.
    ///   - urlSession: Override the URLSession (useful in tests).
    public init(
        orgBaseURL: URL,
        projectSlug: String,
        tokenStore: KeychainTokenStore? = KeychainTokenStore(),
        urlSession: URLSession = .shared
    ) {
        self.client = GateAuthClient(
            baseURL: orgBaseURL,
            session: urlSession,
            projectSlug: projectSlug
        )
        self.tokenStore = tokenStore
    }

    // MARK: - Public API surface

    /// Sign in an existing end-user with email and password.
    ///
    /// Persists the refresh token in the Keychain on success.
    /// Throws `K9OGateError.invalidCredentials` on bad credentials (HTTP 401).
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/signin`
    public func signIn(email: String, password: String) async throws -> K9OAuthResult {
        let result: K9OAuthResult = try await client.post(
            path: "signin",
            body: SignInBody(email: email, password: password),
            responseType: K9OAuthResult.self
        )
        try await tokenStore?.save(result.session.refreshToken)
        return result
    }

    /// Mint a new access token from the stored (or supplied) refresh token.
    ///
    /// If `refreshToken` is `nil`, loads the token from the Keychain. The gateway
    /// answers with a new access token and its expiry only: the refresh token is
    /// NOT rotated, so the stored one is left as it is and stays valid until
    /// `signOut`. The result has no `user`; read the subject from the access
    /// token with `K9OAccessToken.decode`.
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/refresh` with body `{ refreshToken }`.
    public func refreshToken(refreshToken: String? = nil) async throws -> K9ORefreshResult {
        let token: String
        if let explicit = refreshToken {
            token = explicit
        } else if let stored = try await tokenStore?.load() {
            token = stored
        } else {
            throw K9OGateError.unauthenticated
        }
        return try await client.post(
            path: "refresh",
            body: RefreshTokenBody(refreshToken: token),
            responseType: K9ORefreshResult.self
        )
    }

    /// Sign out the current session. Deletes the Keychain-stored refresh token.
    ///
    /// If `refreshToken` is `nil`, loads the token from the Keychain; with none,
    /// nothing is sent. Returns `true` when the gateway revoked a live session and
    /// `false` when the token was unknown or already revoked (sign-out is
    /// idempotent; the stored token is deleted either way).
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/signout` with body `{ refreshToken }`.
    @discardableResult
    public func signOut(refreshToken: String? = nil) async throws -> Bool {
        let token: String
        if let explicit = refreshToken {
            token = explicit
        } else if let stored = try await tokenStore?.load() {
            token = stored
        } else {
            return false // Already signed out; nothing sent.
        }
        let result: SignOutResponse = try await client.post(
            path: "signout",
            body: SignOutBody(refreshToken: token),
            responseType: SignOutResponse.self
        )
        try await tokenStore?.delete()
        return result.revoked
    }
}

// MARK: - Internal helpers

private struct SignOutResponse: Decodable { let revoked: Bool }
