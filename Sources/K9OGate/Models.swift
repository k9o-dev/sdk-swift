import Foundation

// MARK: - Core model types (mirror @k9o/gate TypeScript types)

/// Project-level end-user identity. IDs carry the `eu_` prefix.
public struct K9OEndUser: Codable, Sendable {
    public let id: String
    public let email: String
    public let status: String
    public let createdAt: String
    public let updatedAt: String?
    public let lastSigninAt: String?
    public let roles: [String]
    public let groups: [String]
}

/// Session tokens returned by sign-in / sign-up / refresh flows.
/// Both tokens are opaque to the SDK consumer; `accessToken` carries
/// a JWT that Gate-aware backend services validate; `refreshToken` is
/// presented back to `refreshToken(...)` to rotate the access token.
public struct K9OSession: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    /// ISO 8601 instant the access token expires.
    public let expiresAt: String
}

/// Returned by signIn and refreshToken.
public struct K9OAuthResult: Codable, Sendable {
    public let user: K9OEndUser
    public let session: K9OSession
}

/// Standard response envelope — matches `{ data, meta }` shape.
struct K9OEnvelope<T: Decodable>: Decodable {
    let data: T
    let meta: [String: AnyCodable]?
}

// MARK: - Lightweight JWT access-token decoder

/// Lightweight access-token decoder. Decodes the JWT payload without
/// signature verification (the gateway validates signatures; the SDK
/// consumer trusts transport security + token issuance source).
///
/// Exposes standard claims plus the `ext.<namespace>.<name>` custom-
/// claim flatten introduced at (e.g. `customClaims["partners"]?["partner_role"]`).
public struct K9OAccessToken: Sendable {
    /// JWT `sub` — typically the `eu_<base62>` end-user ID.
    public let subject: String?
    /// JWT `exp` — Unix timestamp at which the token expires.
    public let expiresAt: Date?
    /// JWT `iat` — Unix timestamp at which the token was issued.
    public let issuedAt: Date?
    /// JWT `iss`.
    public let issuer: String?
    /// Raw decoded payload for access to all claims.
    public let allClaims: [String: Any]

    /// Custom claims namespaced under `ext.<namespace>` per
    /// flatten. Key is the namespace name (e.g. "partners"), value
    /// is a dictionary of claim name → value.
    ///
    /// Example: `customClaims["partners"]?["partner_role"]` → "extension_org_admin"
    public var customClaims: [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for (key, value) in allClaims {
            guard key.hasPrefix("ext."), let dict = value as? [String: Any] else { continue }
            let namespace = String(key.dropFirst("ext.".count))
            result[namespace] = dict
        }
        return result
    }

    /// Decode a raw JWT string into a `K9OAccessToken`.
    /// Returns `nil` if the input is not a structurally valid JWT.
    public static func decode(_ jwt: String) -> K9OAccessToken? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let payloadB64 = String(parts[1])
        // base64url → base64 padding
        var padded = payloadB64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder != 0 { padded += String(repeating: "=", count: 4 - remainder) }
        guard let payloadData = Data(base64Encoded: padded),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { return nil }

        let subject = json["sub"] as? String
        let issuer = json["iss"] as? String
        let expiresAt = (json["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let issuedAt = (json["iat"] as? Double).map { Date(timeIntervalSince1970: $0) }

        return K9OAccessToken(
            subject: subject,
            expiresAt: expiresAt,
            issuedAt: issuedAt,
            issuer: issuer,
            allClaims: json
        )
    }
}

// MARK: - AnyCodable helper for meta dictionary

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let string = try? container.decode(String.self) { value = string }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let bool as Bool: try container.encode(bool)
        case let string as String: try container.encode(string)
        default: try container.encodeNil()
        }
    }
}
