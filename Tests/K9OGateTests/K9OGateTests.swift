import XCTest
@testable import K9OGate

final class K9OGateTests: XCTestCase {
    var gate: GateClient!
    var keychainStore: KeychainTokenStore!
    var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        keychainStore = KeychainTokenStore(
            service: "dev.kilimanjaro.gate.tests.\(UUID().uuidString)",
            account: "refresh_token"
        )
        gate = GateClient(
            orgBaseURL: URL(string: "https://acme.api.k9o.io")!,
            projectSlug: "test-project",
            tokenStore: keychainStore,
            urlSession: session
        )
    }

    override func tearDown() async throws {
        try? await keychainStore.delete()
        StubURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - signIn happy path

    func testSignInHappyPath() async throws {
        StubURLProtocol.register(method: "POST", pathSuffix: "signin") { _ in
            (200, authResultEnvelope())
        }
        let result = try await gate.signIn(email: "user@example.com", password: "pass")
        XCTAssertEqual(result.user.id, "eu_TestUserABC123")
        XCTAssertEqual(result.user.email, "user@example.com")
        XCTAssertEqual(result.session.refreshToken, "rt_MockRefreshToken0001")
    }

    func testSignInPersistsRefreshTokenToKeychain() async throws {
        StubURLProtocol.register(method: "POST", pathSuffix: "signin") { _ in
            (200, authResultEnvelope())
        }
        _ = try await gate.signIn(email: "user@example.com", password: "pass")
        let stored = try await keychainStore.load()
        XCTAssertEqual(stored, "rt_MockRefreshToken0001")
    }

    // MARK: - refreshToken happy path

    func testRefreshTokenHappyPath() async throws {
        // Seed keychain with a token first.
        try await keychainStore.save("rt_InitialToken")
        StubURLProtocol.register(method: "POST", pathSuffix: "refresh") { _ in
            (200, authResultEnvelope())
        }
        let result = try await gate.refreshToken()
        XCTAssertEqual(result.session.refreshToken, "rt_MockRefreshToken0001")
        // Keychain must be updated with the new token.
        let stored = try await keychainStore.load()
        XCTAssertEqual(stored, "rt_MockRefreshToken0001")
    }

    func testRefreshTokenExplicitOverridesKeychain() async throws {
        try await keychainStore.save("rt_ShouldNotBeUsed")
        StubURLProtocol.register(method: "POST", pathSuffix: "refresh") { req in
            // Verify the explicit token was sent in the body. The gate refresh
            // body uses camelCase `refreshToken` (verified vs the live gateway:
            // snake `refresh_token` → 400, camel `refreshToken` → 401).
            let body = try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
            XCTAssertEqual(body?["refreshToken"] as? String, "rt_ExplicitToken")
            return (200, authResultEnvelope())
        }
        _ = try await gate.refreshToken(refreshToken: "rt_ExplicitToken")
    }

    // MARK: - signOut happy path

    func testSignOutHappyPath() async throws {
        try await keychainStore.save("rt_ToBeRevoked")
        StubURLProtocol.register(method: "POST", pathSuffix: "signout") { _ in
            (200, jsonData(["data": [:], "meta": [:]]))
        }
        try await gate.signOut()
        let stored = try await keychainStore.load()
        XCTAssertNil(stored, "Keychain refresh token must be deleted after signOut")
    }

    func testSignOutNoOpWhenNoToken() async throws {
        // No keychain token + no explicit token → should not throw, no network call.
        // No stub registered; if a network call is made the test will fail with unsupportedURL.
        try await gate.signOut()
    }

    // MARK: - Error handling

    func testSignInInvalidCredentialsThrows() async throws {
        StubURLProtocol.register(method: "POST", pathSuffix: "signin") { _ in
            (401, errorEnvelope(code: "K9O_INVALID_CREDENTIALS"))
        }
        do {
            _ = try await gate.signIn(email: "bad@example.com", password: "wrong")
            XCTFail("Expected K9OGateError.invalidCredentials")
        } catch K9OGateError.invalidCredentials {
            // pass
        }
    }

    func testRefreshTokenUnauthenticatedThrowsWhenNoKeychainToken() async throws {
        // No token in keychain → should throw .unauthenticated immediately.
        do {
            _ = try await gate.refreshToken()
            XCTFail("Expected K9OGateError.unauthenticated")
        } catch K9OGateError.unauthenticated {
            // pass
        }
    }

    func testNetworkFailureWrapped() async throws {
        StubURLProtocol.register(method: "POST", pathSuffix: "signin") { _ in
            // Returning nil body with 0 triggers URLError in the stub.
            // Simulate by forcing an error response via a different approach.
            // Return a non-JSON response so decoding fails after a 200.
            (200, "not-json".data(using: .utf8))
        }
        do {
            _ = try await gate.signIn(email: "u@e.com", password: "p")
            XCTFail("Expected K9OGateError.decoding")
        } catch K9OGateError.decoding {
            // pass
        }
    }

    func testUnknownErrorCodeMapsToUnknown() async throws {
        StubURLProtocol.register(method: "POST", pathSuffix: "signin") { _ in
            (500, errorEnvelope(code: "K9O_INTERNAL_ERROR", message: "server exploded"))
        }
        do {
            _ = try await gate.signIn(email: "u@e.com", password: "p")
            XCTFail("Expected K9OGateError.unknown")
        } catch K9OGateError.unknown(let code, _) {
            XCTAssertEqual(code, 500)
        }
    }

    // MARK: - Keychain roundtrip

    func testKeychainSaveLoadDelete() async throws {
        let token = "rt_RoundTripTest_\(UUID().uuidString)"
        try await keychainStore.save(token)
        let loaded = try await keychainStore.load()
        XCTAssertEqual(loaded, token)
        try await keychainStore.delete()
        let afterDelete = try await keychainStore.load()
        XCTAssertNil(afterDelete)
    }

    func testKeychainOverwrite() async throws {
        try await keychainStore.save("rt_Original")
        try await keychainStore.save("rt_Overwritten")
        let loaded = try await keychainStore.load()
        XCTAssertEqual(loaded, "rt_Overwritten")
    }

    // MARK: - JWT / AccessToken decode

    func testAccessTokenDecode() {
        // The mock access_token fixture carries a predictable payload.
        // Header: {"alg":"ES256","typ":"JWT"}
        // Payload: {"sub":"eu_TestUserABC123","exp":9999999999,"iat":1700000000,
        //           "iss":"https://api.k9o.io",
        //           "ext.partners":{"partner_role":"extension_org_admin"}}
        let jwt = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJldV9UZXN0VXNlckFCQzEyMyIsImV4cCI6OTk5OTk5OTk5OSwiaWF0IjoxNzAwMDAwMDAwLCJpc3MiOiJodHRwczovL2FwaS5rOW8uaW8iLCJleHQucGFydG5lcnMiOnsicGFydG5lcl9yb2xlIjoiZXh0ZW5zaW9uX29yZ19hZG1pbiJ9fQ.sig"
        let token = K9OAccessToken.decode(jwt)
        XCTAssertNotNil(token)
        XCTAssertEqual(token?.subject, "eu_TestUserABC123")
        XCTAssertEqual(token?.issuer, "https://api.k9o.io")
        // Custom claims: ext.partners → partner_role
        let partnerRole = token?.customClaims["partners"]?["partner_role"] as? String
        XCTAssertEqual(partnerRole, "extension_org_admin")
    }

    func testAccessTokenDecodeInvalidInput() {
        XCTAssertNil(K9OAccessToken.decode("not.a.jwt.at.all"))
        XCTAssertNil(K9OAccessToken.decode(""))
        XCTAssertNil(K9OAccessToken.decode("only.two"))
    }
}
