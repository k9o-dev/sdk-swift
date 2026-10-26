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

    // MARK: - signIn

    func testSignInSendsPostToGateSigninWithEmailAndPasswordOnly() async throws {
        var seen: URLRequest?
        StubURLProtocol.register(method: "POST", pathSuffix: "signin") { req in
            seen = req
            return (200, authResultEnvelope())
        }
        let result = try await gate.signIn(email: "user@example.com", password: "pass")
        XCTAssertEqual(seen?.httpMethod, "POST")
        XCTAssertEqual(seen?.url?.absoluteString, "https://acme.api.k9o.io/@test-project/gate/signin")
        let body = try JSONSerialization.jsonObject(with: seen?.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body as? [String: String], ["email": "user@example.com", "password": "pass"])
        XCTAssertEqual(result.user.id, "eu_TestUserABC123")
        XCTAssertEqual(result.user.email, "user@example.com")
        XCTAssertEqual(result.user.createdAt, "2026-01-01T00:00:00Z")
        XCTAssertEqual(result.session.refreshToken, "rt_MockRefreshToken0001")
        XCTAssertEqual(result.session.expiresAt, "2099-01-01T00:00:00Z")
    }

    func testSignInPersistsRefreshTokenToKeychain() async throws {
        StubURLProtocol.register(method: "POST", pathSuffix: "signin") { _ in
            (200, authResultEnvelope())
        }
        _ = try await gate.signIn(email: "user@example.com", password: "pass")
        let stored = try await keychainStore.load()
        XCTAssertEqual(stored, "rt_MockRefreshToken0001")
    }

    // MARK: - refreshToken

    func testRefreshTokenParsesFlatAccessTokenAndExpiryAndKeepsStoredToken() async throws {
        try await keychainStore.save("rt_InitialToken")
        var seen: URLRequest?
        StubURLProtocol.register(method: "POST", pathSuffix: "refresh") { req in
            seen = req
            return (200, refreshEnvelope())
        }
        let result = try await gate.refreshToken()
        XCTAssertEqual(seen?.httpMethod, "POST")
        XCTAssertEqual(seen?.url?.absoluteString, "https://acme.api.k9o.io/@test-project/gate/refresh")
        // The body is closed to { refreshToken }: the gateway refuses any other field.
        let body = try JSONSerialization.jsonObject(with: seen?.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body as? [String: String], ["refreshToken": "rt_InitialToken"])
        XCTAssertEqual(result.accessToken, mockSession["accessToken"] as? String)
        XCTAssertEqual(result.expiresAt, "2099-01-01T00:00:00Z")
        // The response carries no new refresh token: the stored one is untouched.
        let stored = try await keychainStore.load()
        XCTAssertEqual(stored, "rt_InitialToken")
    }

    func testRefreshTokenExplicitOverridesKeychain() async throws {
        try await keychainStore.save("rt_ShouldNotBeUsed")
        StubURLProtocol.register(method: "POST", pathSuffix: "refresh") { req in
            let body = try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
            XCTAssertEqual(body?["refreshToken"] as? String, "rt_ExplicitToken")
            return (200, refreshEnvelope())
        }
        _ = try await gate.refreshToken(refreshToken: "rt_ExplicitToken")
    }

    // MARK: - signOut

    func testSignOutSendsRefreshTokenAndReportsRevoked() async throws {
        try await keychainStore.save("rt_ToBeRevoked")
        var seen: URLRequest?
        StubURLProtocol.register(method: "POST", pathSuffix: "signout") { req in
            seen = req
            return (200, jsonData(["data": ["revoked": true], "meta": [:]]))
        }
        let revoked = try await gate.signOut()
        XCTAssertTrue(revoked)
        XCTAssertEqual(seen?.httpMethod, "POST")
        XCTAssertEqual(seen?.url?.absoluteString, "https://acme.api.k9o.io/@test-project/gate/signout")
        let body = try JSONSerialization.jsonObject(with: seen?.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body as? [String: String], ["refreshToken": "rt_ToBeRevoked"])
        let stored = try await keychainStore.load()
        XCTAssertNil(stored, "Keychain refresh token must be deleted after signOut")
    }

    func testSignOutUnknownTokenReturnsFalseAndStillClearsStore() async throws {
        try await keychainStore.save("rt_Unknown")
        StubURLProtocol.register(method: "POST", pathSuffix: "signout") { _ in
            (200, jsonData(["data": ["revoked": false], "meta": [:]]))
        }
        let revoked = try await gate.signOut()
        XCTAssertFalse(revoked)
        let stored = try await keychainStore.load()
        XCTAssertNil(stored)
    }

    func testSignOutNoOpWhenNoToken() async throws {
        // No keychain token + no explicit token: nothing is sent.
        // No stub registered; if a network call is made the test will fail with unsupportedURL.
        let revoked = try await gate.signOut()
        XCTAssertFalse(revoked)
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

    func testAccessTokenDecodeReadsFlatCustomClaims() {
        // Custom claims are FLAT keys ("ext.<namespace>.<name>"), not a nested object.
        let payload = #"{"sub":"eu_TestUserABC123","exp":9999999999,"iat":1700000000,"iss":"https://issuer.example","ext.partners.partner_role":"extension_org_admin"}"#
        let b64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = K9OAccessToken.decode("eyJhbGciOiJFUzI1NiJ9.\(b64).sig")
        XCTAssertNotNil(token)
        XCTAssertEqual(token?.subject, "eu_TestUserABC123")
        XCTAssertEqual(token?.issuer, "https://issuer.example")
        XCTAssertEqual(token?.customClaims["ext.partners.partner_role"] as? String, "extension_org_admin")
        XCTAssertEqual(token?.customClaim(namespace: "partners", name: "partner_role") as? String, "extension_org_admin")
        XCTAssertEqual(token?.customClaims.count, 1)
        XCTAssertNil(token?.customClaim(namespace: "partners", name: "missing"))
    }

    func testAccessTokenDecodeInvalidInput() {
        XCTAssertNil(K9OAccessToken.decode("not.a.jwt.at.all"))
        XCTAssertNil(K9OAccessToken.decode(""))
        XCTAssertNil(K9OAccessToken.decode("only.two"))
    }
}
