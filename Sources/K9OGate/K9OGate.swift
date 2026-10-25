import Foundation

/// Kilimanjaro Gate IAK Swift SDK — v0.3.0
///
/// `GateClient` is the primary entry point. Initialise once per project
/// and call the three marquee methods that mirror the @k9o/gate TypeScript
/// surface: `signIn`, `refreshToken`, and `signOut`.
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

    /// Rotate the access token using the stored (or supplied) refresh token.
    ///
    /// If `refreshToken` is `nil`, loads the token from the Keychain. Updates
    /// the Keychain with the new refresh token on success.
    ///
    /// - Parameter projectHint: Optional `project_<id>` hint;
    ///   pass `nil` for most single-project configurations.
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/refresh`
    public func refreshToken(
        refreshToken: String? = nil,
        projectHint: String? = nil
    ) async throws -> K9OAuthResult {
        let token: String
        if let explicit = refreshToken {
            token = explicit
        } else if let stored = try await tokenStore?.load() {
            token = stored
        } else {
            throw K9OGateError.unauthenticated
        }
        let result: K9OAuthResult = try await client.post(
            path: "refresh",
            body: RefreshTokenBody(refreshToken: token, projectHint: projectHint),
            responseType: K9OAuthResult.self
        )
        try await tokenStore?.save(result.session.refreshToken)
        return result
    }

    /// Sign out the current session. Deletes the Keychain-stored refresh token.
    ///
    /// If `refreshToken` is `nil`, loads the token from the Keychain.
    ///
    /// Mirrors: `POST /@<projectSlug>/gate/signout`
    public func signOut(refreshToken: String? = nil) async throws {
        let token: String
        if let explicit = refreshToken {
            token = explicit
        } else if let stored = try await tokenStore?.load() {
            token = stored
        } else {
            return // Already signed out; no-op.
        }
        _ = try await client.post(
            path: "signout",
            body: SignOutBody(refreshToken: token),
            responseType: EmptyResponse.self
        )
        try await tokenStore?.delete()
    }
}

// MARK: - Internal helpers

private struct EmptyResponse: Decodable {}
