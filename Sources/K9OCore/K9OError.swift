import Foundation

/// Minimal JSON value, used for the open-shaped `context` of a KError.
public enum K9OJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([K9OJSON])
    case object([String: K9OJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([K9OJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: K9OJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// Platform error. Wire shape on non-2xx is FLAT: `{ code, message, context, recommendation }`.
/// Request bodies are never placed in the error text.
public struct K9OError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public let code: String
    public let message: String
    public let context: K9OJSON?
    public let recommendation: String?
    /// HTTP status, or nil when no response was received / the error is client-side.
    public let status: Int?

    public init(code: String, message: String, context: K9OJSON? = nil, recommendation: String? = nil, status: Int? = nil) {
        self.code = code
        self.message = message
        self.context = context
        self.recommendation = recommendation
        self.status = status
    }

    public var description: String { "K9OError(\(code)): \(message)" }
    public var errorDescription: String? { description }

    static let upstreamUnavailable = "K9O_UPSTREAM_UNAVAILABLE"
    static let internalError = "K9O_INTERNAL_ERROR"
    static let missingProjectContext = "K9O_MISSING_PROJECT_CONTEXT"
}

private struct K9OErrorWire: Decodable {
    let code: String
    let message: String?
    let context: K9OJSON?
    let recommendation: String?
}

extension K9OError {
    static func fromResponse(status: Int, data: Data) -> K9OError {
        if let w = try? JSONDecoder().decode(K9OErrorWire.self, from: data) {
            return K9OError(code: w.code, message: w.message ?? "", context: w.context,
                            recommendation: w.recommendation, status: status)
        }
        return K9OError(code: internalError,
                        message: "Non-JSON error response (HTTP \(status))", status: status)
    }
}
