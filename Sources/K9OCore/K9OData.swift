import Foundation

/// Text-search query syntax.
public enum K9OTextSearchType: String, Sendable, Equatable { case plain, phrase, websearch }

/// Distance metric for `vectorSearch`.
public enum K9OVectorMetric: String, Sendable, Equatable { case cosine, euclidean, dot }

/// How a select counts the total rows.
public enum K9OCountMode: String, Sendable, Equatable { case none, exact, estimated }

/// The value of an `is` filter.
public enum K9OIsValue: String, Sendable, Equatable { case null, `true`, `false` }

enum K9OFilterOp: String { case eq, neq, gt, gte, lt, lte, `in`, notIn, like, ilike, `is` }

public enum K9OSelectKind: Sendable {}
public enum K9OUpdateKind: Sendable {}
public enum K9ODeleteKind: Sendable {}

/// Chainable query on one collection. Filters compose with AND; each call returns a new builder.
public struct K9OBuilder<Kind>: Sendable {
    let client: K9OCoreClient
    let collection: String
    var payload: (any Encodable & Sendable)?
    var items: [(String, String)] = []   // filters and search parameters, in order; a repeat replaces
    var idFilter: String?
    var limitValue: Int?
    var cursorValue: String?
    var countMode: K9OCountMode?

    init(client: K9OCoreClient, collection: String, payload: (any Encodable & Sendable)? = nil) {
        self.client = client
        self.collection = collection
        self.payload = payload
    }

    mutating func set(_ key: String, _ value: String) {
        if let i = items.firstIndex(where: { $0.0 == key }) { items[i].1 = value } else { items.append((key, value)) }
    }

    mutating func remove(_ key: String) { items.removeAll { $0.0 == key } }

    func adding(_ column: String, _ op: K9OFilterOp, _ text: String, id: K9OValue? = nil) -> Self {
        var b = self
        b.set(column, "\(op.rawValue).\(text)")
        if column == "id" && op == .eq, let id { b.idFilter = id.text }
        return b
    }

    func list(_ values: [some K9OValueConvertible]) -> String {
        "(" + values.map { $0.k9oValue.text }.joined(separator: ",") + ")"
    }

    public func eq(_ column: String, _ value: some K9OValueConvertible) -> Self {
        adding(column, .eq, value.k9oValue.text, id: value.k9oValue)
    }
    public func neq(_ column: String, _ value: some K9OValueConvertible) -> Self { adding(column, .neq, value.k9oValue.text) }
    public func gt(_ column: String, _ value: some K9OValueConvertible) -> Self { adding(column, .gt, value.k9oValue.text) }
    public func gte(_ column: String, _ value: some K9OValueConvertible) -> Self { adding(column, .gte, value.k9oValue.text) }
    public func lt(_ column: String, _ value: some K9OValueConvertible) -> Self { adding(column, .lt, value.k9oValue.text) }
    public func lte(_ column: String, _ value: some K9OValueConvertible) -> Self { adding(column, .lte, value.k9oValue.text) }
    public func `in`(_ column: String, _ values: [some K9OValueConvertible]) -> Self { adding(column, .in, list(values)) }
    public func notIn(_ column: String, _ values: [some K9OValueConvertible]) -> Self { adding(column, .notIn, list(values)) }
    public func like(_ column: String, _ pattern: String) -> Self { adding(column, .like, pattern) }
    public func ilike(_ column: String, _ pattern: String) -> Self { adding(column, .ilike, pattern) }
    public func `is`(_ column: String, _ value: K9OIsValue) -> Self { adding(column, .is, value.rawValue) }

    /// The collection path, or the error the request would fail with before being sent.
    func collectionPath() throws -> String {
        let slug = try client.requireProject("data-plane operations")
        let ok = collection.range(of: "^[a-z][a-z0-9_-]{0,62}$", options: .regularExpression) != nil
        guard ok else {
            throw K9OError.invalidField(
                "collection name \"\(collection)\" does not match required format",
                context: .object(["collection": .string(collection)]),
                recommendation: "Use lowercase letters / digits / underscores / hyphens; start with a letter; 1-63 chars.")
        }
        return "/@\(slug)/data/\(collection)"
    }

    func requireId(_ verb: String, _ noun: String) throws -> String {
        guard let id = idFilter else {
            throw K9OError.invalidField(
                "\(verb)() requires an `.eq(\"id\", \"...\")` filter; \(noun) many rows in one call is not supported",
                context: .object(["collection": .string(collection)]),
                recommendation: "Chain `.eq(\"id\", \"rec_...\")` before executing; to \(verb) several rows, call \(verb) once per id.")
        }
        return id
    }
}

public typealias K9OSelectBuilder = K9OBuilder<K9OSelectKind>
public typealias K9OUpdateBuilder = K9OBuilder<K9OUpdateKind>
public typealias K9ODeleteBuilder = K9OBuilder<K9ODeleteKind>

private let searchColumn = "^[a-zA-Z_][a-zA-Z0-9_]{0,62}$"

extension K9OBuilder where Kind == K9OSelectKind {
    /// Page size.
    public func limit(_ n: Int) -> Self { var b = self; b.limitValue = n; return b }

    /// Opaque cursor from a previous response's `nextCursor` (`meta.cursor.next`).
    public func cursor(_ opaque: String) -> Self { var b = self; b.cursorValue = opaque; return b }

    /// Total-count behaviour: `.none` (default) skips the count, `.exact` counts, `.estimated` reads statistics.
    public func count(_ mode: K9OCountMode) -> Self { var b = self; b.countMode = mode; return b }

    /// Full-text search over one text column. Composes with filters, `limit` and `cursor`.
    /// Throws `K9O_INVALID_FIELD_VALUE` for a bad column, an empty query or a bad language.
    public func textSearch(_ column: String, _ query: String, language: String = "english",
                           type: K9OTextSearchType = .plain) throws -> Self {
        guard column.range(of: searchColumn, options: .regularExpression) != nil else {
            throw K9OError.invalidField("textSearch column '\(column)' is not a valid identifier")
        }
        guard !query.isEmpty else { throw K9OError.invalidField("textSearch query must be non-empty") }
        guard language.range(of: "^[a-zA-Z_]+$", options: .regularExpression) != nil else {
            throw K9OError.invalidField("textSearch language must be a text-search configuration name")
        }
        var b = self
        b.set("textSearch", "\(column):\(query)")
        if language != "english" { b.set("textSearchLanguage", language) } else { b.remove("textSearchLanguage") }
        if type != .plain { b.set("textSearchType", type.rawValue) } else { b.remove("textSearchType") }
        return b
    }

    /// Semantic search: the rows nearest to an embedding in one vector column, closest first.
    /// `limit` is 1 to 1000 (the gateway default is 10). Throws `K9O_INVALID_FIELD_VALUE` for a bad column,
    /// an empty or non-finite embedding, or a limit out of range.
    public func vectorSearch(_ column: String, _ embedding: [Double], metric: K9OVectorMetric = .cosine,
                             limit: Int? = nil) throws -> Self {
        guard column.range(of: searchColumn, options: .regularExpression) != nil else {
            throw K9OError.invalidField("vectorSearch column '\(column)' is not a valid identifier")
        }
        guard !embedding.isEmpty, embedding.allSatisfy({ $0.isFinite }) else {
            throw K9OError.invalidField("vectorSearch embedding must be a non-empty array of numbers")
        }
        if let limit, limit < 1 || limit > 1000 {
            throw K9OError.invalidField("vectorSearch limit must be an integer from 1 to 1000")
        }
        var b = self
        b.set("vectorSearch", "\(column):[\(embedding.map { K9OValue.double($0).text }.joined(separator: ","))]")
        if metric != .cosine { b.set("vectorMetric", metric.rawValue) } else { b.remove("vectorMetric") }
        if let limit { b.set("vectorLimit", String(limit)) } else { b.remove("vectorLimit") }
        return b
    }

    var queryItems: [(String, String)] {
        // Filters and search parameters first, then paging; a later key replaces an earlier one.
        var b = self
        if let limitValue { b.set("limit", String(limitValue)) }
        if let cursorValue { b.set("cursor", cursorValue) }
        if let countMode { b.set("count", countMode.rawValue) }
        return b.items
    }

    /// `GET /@<projectSlug>/data/<collection>` with the filters as query parameters. `data` is the list of rows.
    public func execute() async throws -> K9OEnvelope<[K9ORow]> { try await execute(as: K9ORow.self) }

    /// Like `execute()`, decoding each row into your own type.
    public func execute<Row: Decodable & Sendable>(as: Row.Type) async throws -> K9OEnvelope<[Row]> {
        try await client.send(method: "GET", path: try collectionPath(), query: queryItems, as: [Row].self)
    }
}

extension K9OBuilder where Kind == K9OUpdateKind {
    /// `PATCH /@<projectSlug>/data/<collection>/<id>`. The chain must include `.eq("id", ...)`; otherwise this
    /// throws `K9O_INVALID_FIELD_VALUE` and sends nothing.
    public func execute() async throws -> K9OEnvelope<K9ORow> { try await execute(as: K9ORow.self) }

    public func execute<Row: Decodable & Sendable>(as: Row.Type) async throws -> K9OEnvelope<Row> {
        let id = try requireId("update", "changing")
        let path = "\(try collectionPath())/\(K9OCoreClient.segmentEncode(id))"
        return try await client.send(method: "PATCH", path: path, body: payload.map { .json($0) }, as: Row.self)
    }
}

extension K9OBuilder where Kind == K9ODeleteKind {
    /// `DELETE /@<projectSlug>/data/<collection>/<id>`. The chain must include `.eq("id", ...)`; otherwise this
    /// throws `K9O_INVALID_FIELD_VALUE` and sends nothing.
    public func execute() async throws -> K9OEnvelope<K9ORow> { try await execute(as: K9ORow.self) }

    public func execute<Row: Decodable & Sendable>(as: Row.Type) async throws -> K9OEnvelope<Row> {
        let id = try requireId("delete", "deleting")
        let path = "\(try collectionPath())/\(K9OCoreClient.segmentEncode(id))"
        return try await client.send(method: "DELETE", path: path, as: Row.self)
    }
}

/// Entry point of the data DSL: `core.from("posts")`.
public struct K9OFrom: Sendable {
    let client: K9OCoreClient
    let collection: String

    /// Start a select; add filters, then call `execute()`.
    public func select() -> K9OSelectBuilder { K9OBuilder(client: client, collection: collection) }

    /// `POST /@<projectSlug>/data/<collection>`: insert one record. Returns it with its generated `id`.
    public func insert(_ record: some Encodable & Sendable) async throws -> K9OEnvelope<K9ORow> {
        try await insert(record, as: K9ORow.self)
    }

    public func insert<Row: Decodable & Sendable>(_ record: some Encodable & Sendable,
                                                  as: Row.Type) async throws -> K9OEnvelope<Row> {
        let b = K9OSelectBuilder(client: client, collection: collection)
        return try await client.send(method: "POST", path: try b.collectionPath(), body: .json(record), as: Row.self)
    }

    /// Start an update of one record; chain `.eq("id", ...)`, then `execute()`.
    public func update(_ patch: some Encodable & Sendable) -> K9OUpdateBuilder {
        K9OBuilder(client: client, collection: collection, payload: patch)
    }

    /// Start a delete of one record; chain `.eq("id", ...)`, then `execute()`.
    public func delete() -> K9ODeleteBuilder { K9OBuilder(client: client, collection: collection) }
}
