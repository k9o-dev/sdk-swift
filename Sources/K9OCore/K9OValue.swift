import Foundation

/// A value that can be bound to a SQL placeholder or used in a filter: string, number, boolean or null.
public enum K9OValue: Sendable, Equatable, Encodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(_ value: some K9OValueConvertible) { self = value.k9oValue }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    /// The text form used in filter query strings (`eq.5`, `eq.true`).
    var text: String {
        switch self {
        case .string(let v): return v
        case .int(let v): return String(v)
        case .double(let v):
            if v == v.rounded(), abs(v) < 1e15 { return String(Int(v)) }
            return String(v)
        case .bool(let v): return v ? "true" : "false"
        case .null: return "null"
        }
    }

    /// Throws `K9O_INVALID_FIELD_VALUE` for a number that is not finite.
    func checked(_ what: String) throws -> K9OValue {
        if case .double(let d) = self, !d.isFinite {
            throw K9OError.invalidField("\(what) must be a finite number, string, boolean or null; serialise anything else (for example as JSON text) first")
        }
        return self
    }
}

extension K9OValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
}

/// Swift values that map onto a `K9OValue`.
public protocol K9OValueConvertible: Sendable { var k9oValue: K9OValue { get } }
extension String: K9OValueConvertible { public var k9oValue: K9OValue { .string(self) } }
extension Int: K9OValueConvertible { public var k9oValue: K9OValue { .int(self) } }
extension Double: K9OValueConvertible { public var k9oValue: K9OValue { .double(self) } }
extension Bool: K9OValueConvertible { public var k9oValue: K9OValue { .bool(self) } }
extension K9OValue: K9OValueConvertible { public var k9oValue: K9OValue { self } }

extension K9OError {
    static let invalidFieldValue = "K9O_INVALID_FIELD_VALUE"

    static func invalidField(_ message: String, context: K9OJSON? = nil, recommendation: String? = nil) -> K9OError {
        K9OError(code: invalidFieldValue, message: message, context: context, recommendation: recommendation)
    }
}
