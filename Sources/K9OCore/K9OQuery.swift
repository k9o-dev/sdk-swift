import Foundation

/// Parameters for `query`: a list (positional, bound to `$1`, `$2`, ...) or a map of named values
/// (`:name` placeholders in the SQL).
public enum K9OQueryParams: Sendable, Equatable, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    case positional([K9OValue])
    case named([String: K9OValue])

    public init(arrayLiteral elements: K9OValue...) { self = .positional(elements) }
    public init(dictionaryLiteral elements: (String, K9OValue)...) {
        self = .named(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

private struct QueryBody: Encodable {
    let sql: String
    let params: [K9OValue]

    private enum CodingKeys: String, CodingKey { case sql, params }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sql, forKey: .sql)
        if !params.isEmpty { try c.encode(params, forKey: .params) }  // omitted when empty
    }
}

/// One result row.
public typealias K9ORow = [String: K9OJSON]

enum K9OQueryTranslator {
    private static func isIdentStart(_ c: Unicode.Scalar) -> Bool {
        (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A) || c == "_"
    }
    private static func isIdentChar(_ c: Unicode.Scalar) -> Bool {
        isIdentStart(c) || (c.value >= 0x30 && c.value <= 0x39)
    }

    /// Rewrites `:name` placeholders to `$n`. Skips quoted text, comments, dollar-quoted strings and `::` casts.
    static func translate(_ sql: String, named: [String: K9OValue]) throws -> (sql: String, params: [K9OValue]) {
        let s = Array(sql.unicodeScalars)
        let n = s.count
        var order: [String] = []
        var out = String.UnicodeScalarView()
        var i = 0

        func copy(_ from: Int, _ to: Int) { out.append(contentsOf: s[from..<min(to, n)]) }
        func at(_ k: Int) -> Unicode.Scalar? { k >= 0 && k < n ? s[k] : nil }

        while i < n {
            let c = s[i]
            let next = at(i + 1)
            let prevIsIdent = i > 0 && isIdentChar(s[i - 1])
            if c == "'" || ((c == "E" || c == "e") && next == "'" && !prevIsIdent) {
                let escapes = c != "'"
                var j = escapes ? i + 2 : i + 1
                while j < n {
                    if escapes && s[j] == "\\" { j += 2; continue }
                    if s[j] == "'" {
                        if at(j + 1) == "'" { j += 2; continue }
                        break
                    }
                    j += 1
                }
                copy(i, j + 1)
                i = j + 1
            } else if c == "\"" {
                var j = i + 1
                while j < n {
                    if s[j] == "\"" {
                        if at(j + 1) == "\"" { j += 2; continue }
                        break
                    }
                    j += 1
                }
                copy(i, j + 1)
                i = j + 1
            } else if c == "-" && next == "-" {
                var j = i
                while j < n && s[j] != "\n" { j += 1 }
                copy(i, j)
                i = j
            } else if c == "/" && next == "*" {
                var depth = 1
                var j = i + 2
                while j < n && depth > 0 {
                    if s[j] == "/" && at(j + 1) == "*" { depth += 1; j += 2 }
                    else if s[j] == "*" && at(j + 1) == "/" { depth -= 1; j += 2 }
                    else { j += 1 }
                }
                copy(i, j)
                i = j
            } else if c == "$" {
                // $tag$ ... $tag$ (the tag may be empty)
                var j = i + 1
                if let f = at(j), isIdentStart(f) {
                    j += 1
                    while let ch = at(j), isIdentChar(ch) { j += 1 }
                }
                if at(j) == "$" {
                    let tag = Array(s[i...j])
                    var end = n
                    var k = j + 1
                    while k + tag.count <= n {
                        if Array(s[k..<(k + tag.count)]) == tag { end = k + tag.count; break }
                        k += 1
                    }
                    copy(i, end)
                    i = end
                } else {
                    out.append(c)
                    i += 1
                }
            } else if c == ":" && next == ":" {
                copy(i, i + 2)
                i += 2
            } else if c == ":", let f = next, isIdentStart(f), !prevIsIdent, !(i > 0 && s[i - 1] == ":") {
                var j = i + 2
                while j < n && isIdentChar(s[j]) { j += 1 }
                var name = String.UnicodeScalarView()
                name.append(contentsOf: s[(i + 1)..<j])
                let key = String(name)
                var idx = order.firstIndex(of: key)
                if idx == nil {
                    guard named[key] != nil else {
                        throw K9OError.invalidField("no value for :\(key)", context: .object(["name": .string(key)]))
                    }
                    order.append(key)
                    idx = order.count - 1
                }
                out.append(contentsOf: "$\(idx! + 1)".unicodeScalars)
                i = j
            } else {
                out.append(c)
                i += 1
            }
        }
        let params = try order.map { try named[$0]!.checked("the value for :\($0)") }
        return (String(out), params)
    }
}

extension K9OCoreClient {
    /// `POST /@<projectSlug>/query`: run one read-only SQL statement and read the rows in `data`.
    ///
    /// `params` is a list (bound to `$1`, `$2`, ...; the SQL is sent as written) or a map of named values
    /// (`:name` placeholders are rewritten to `$n` here). Values are bound by the database, never interpolated.
    /// Writes are refused with `K9O_RAW_SQL_READ_ONLY`; mutate through `from(_:)`. One statement per call, row-level
    /// security applies, at most 100000 characters of SQL and 1000 parameters, project-editor role required.
    /// Throws `K9O_INVALID_FIELD_VALUE` (no request sent) for a named placeholder without a value or a number
    /// that is not finite, and `K9O_MISSING_PROJECT_CONTEXT` when the client has no `projectSlug`.
    public func query(_ sql: String, params: K9OQueryParams? = nil) async throws -> K9OEnvelope<[K9ORow]> {
        try await query(sql, params: params, as: K9ORow.self)
    }

    /// Like `query(_:params:)`, decoding each row into your own type.
    public func query<Row: Decodable & Sendable>(_ sql: String, params: K9OQueryParams? = nil,
                                                 as: Row.Type) async throws -> K9OEnvelope<[Row]> {
        let slug = try requireProject("query operations")
        var text = sql
        var values: [K9OValue] = []
        switch params {
        case .none: break
        case .positional(let list):
            values = try list.enumerated().map { try $0.element.checked("params[\($0.offset)]") }
        case .named(let map):
            (text, values) = try K9OQueryTranslator.translate(sql, named: map)
        }
        return try await send(method: "POST", path: "/@\(slug)/query",
                              body: .json(QueryBody(sql: text, params: values)), as: [Row].self)
    }

    /// `search`: full-text search over one text column of a collection, best matches first.
    /// Sugar for `from(collection).select().textSearch(column, q, ...)` plus an optional page `limit` and `cursor`.
    public func search(_ collection: String, column: String, q: String, language: String = "english",
                       type: K9OTextSearchType = .plain, limit: Int? = nil,
                       cursor: String? = nil) async throws -> K9OEnvelope<[K9ORow]> {
        var builder = try from(collection).select().textSearch(column, q, language: language, type: type)
        if let limit { builder = builder.limit(limit) }
        if let cursor { builder = builder.cursor(cursor) }
        return try await builder.execute()
    }
}
