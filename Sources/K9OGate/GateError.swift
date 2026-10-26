import Foundation

/// Errors thrown by K9OGate SDK methods.
///
/// Maps the closed KError taxonomy from the gateway wire format.
/// The `.unknown` case carries the raw HTTP status code and optional
/// body text for diagnostics when the server returns an unrecognised
/// error code.
public enum K9OGateError: Error, Sendable {
    /// The session token is missing, expired, or revoked (HTTP 401).
    case unauthenticated
    /// The caller lacks permission for the requested operation (HTTP 403).
    case forbidden
    /// Email/password (or other credential) did not match (HTTP 401 INVALID_CREDENTIALS).
    case invalidCredentials
    /// A transport-level failure — DNS, TCP, timeout, etc.
    case network(Error)
    /// The gateway response could not be decoded into the expected shape.
    case decoding(Error)
    /// Any other non-2xx status not covered by the cases above.
    case unknown(statusCode: Int, body: String?)
}

extension K9OGateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthenticated:
            return "Session expired or not authenticated."
        case .forbidden:
            return "Access forbidden for the current session."
        case .invalidCredentials:
            return "Invalid credentials."
        case .network(let err):
            return "Network error: \(err.localizedDescription)"
        case .decoding(let err):
            return "Response decoding error: \(err.localizedDescription)"
        case .unknown(let code, let body):
            return "Unexpected error (HTTP \(code)): \(body ?? "<no body>")"
        }
    }
}

// MARK: - Wire error envelope

/// The error object shape returned by the gateway on non-2xx responses.
/// The gateway emits a KError at the ROOT of the error body:
/// `{ code, message, context?, recommendation? }` — NOT wrapped in `{ error: … }`.
struct GateErrorWire: Decodable {
    let code: String
    let message: String?
}

extension K9OGateError {
    static func from(statusCode: Int, data: Data) -> K9OGateError {
        if let wire = try? JSONDecoder().decode(GateErrorWire.self, from: data) {
            // Wire codes are platform-namespaced (`K9O_*`); strip the
            // prefix to match the typed cases.
            let code = wire.code.hasPrefix("K9O_") ? String(wire.code.dropFirst("K9O_".count)) : wire.code
            switch code {
            case "UNAUTHENTICATED", "SESSION_EXPIRED", "MISSING_TOKEN":
                return .unauthenticated
            case "FORBIDDEN":
                return .forbidden
            case "INVALID_CREDENTIALS":
                return .invalidCredentials
            default:
                let body = String(data: data, encoding: .utf8)
                return .unknown(statusCode: statusCode, body: body)
            }
        }
        let body = String(data: data, encoding: .utf8)
        return .unknown(statusCode: statusCode, body: body)
    }
}
