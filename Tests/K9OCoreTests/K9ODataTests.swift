import XCTest
@testable import K9OCore

final class K9ODataTests: XCTestCase {
    private func client(_ rec: Recorder, json: Any = envelope([])) -> K9OCoreClient { makeClient(okTransport(rec, json: json)) }

    func testSelectWireShape() async throws {
        let rec = Recorder()
        let r = try await client(rec, json: ["data": [["id": "a"]], "meta": ["cursor": ["next": "c2"]]])
            .from("posts").select().eq("status", "open").gte("n", 3).`in`("tag", ["a", "b"]).notIn("k", [1, 2])
            .like("t", "x%").ilike("u", "y%").`is`("d", .null).neq("z", true).gt("g", 1.5).lt("l", 9).lte("m", 4)
            .limit(5).cursor("c1").count(.exact).execute()
        XCTAssertEqual(rec.last.httpMethod, "GET")
        XCTAssertEqual(rec.path, "/@tasks-app/data/posts")
        XCTAssertEqual(rec.query, [
            "status": "eq.open", "n": "gte.3", "tag": "in.(a,b)", "k": "notIn.(1,2)", "t": "like.x%", "u": "ilike.y%",
            "d": "is.null", "z": "neq.true", "g": "gt.1.5", "l": "lt.9", "m": "lte.4",
            "limit": "5", "cursor": "c1", "count": "exact",
        ])
        XCTAssertEqual(rec.last.value(forHTTPHeaderField: "Authorization"), "Bearer tok_abc")
        XCTAssertNil(rec.last.httpBody)
        XCTAssertEqual(r.data.count, 1)
        XCTAssertEqual(r.nextCursor, "c2")
    }

    func testSelectWithNoFiltersHasNoQueryString() async throws {
        let rec = Recorder()
        _ = try await client(rec).from("posts").select().execute()
        XCTAssertEqual(rec.url, "https://acme.api.k9o.io/@tasks-app/data/posts")
    }

    func testSameColumnLaterFilterReplaces() async throws {
        let rec = Recorder()
        _ = try await client(rec).from("posts").select().eq("a", 1).eq("a", 2).execute()
        XCTAssertEqual(rec.query, ["a": "eq.2"])
    }

    func testInsertWireShape() async throws {
        struct Post: Encodable, Sendable { let title: String }
        let rec = Recorder()
        let r = try await client(rec, json: envelope(["id": "rec_1", "title": "Hi"])).from("posts").insert(Post(title: "Hi"))
        XCTAssertEqual(rec.last.httpMethod, "POST")
        XCTAssertEqual(rec.path, "/@tasks-app/data/posts")
        XCTAssertEqual(rec.lastBody as? [String: String], ["title": "Hi"])
        XCTAssertEqual(r.data["id"], .string("rec_1"))
    }

    func testUpdateWireShape() async throws {
        let rec = Recorder()
        _ = try await client(rec, json: envelope(["id": "rec_1"]))
            .from("posts").update(["title": K9OJSON.string("New")]).eq("id", "rec_1").execute()
        XCTAssertEqual(rec.last.httpMethod, "PATCH")
        XCTAssertEqual(rec.path, "/@tasks-app/data/posts/rec_1")
        XCTAssertEqual(rec.lastBody as? [String: String], ["title": "New"])
    }

    func testDeleteWireShapeEncodesId() async throws {
        let rec = Recorder()
        _ = try await client(rec, json: envelope(["id": "a/b"])).from("posts").delete().eq("id", "a/b").execute()
        XCTAssertEqual(rec.last.httpMethod, "DELETE")
        XCTAssertEqual(rec.path, "/@tasks-app/data/posts/a%2Fb")
        XCTAssertNil(rec.last.httpBody)
    }

    func testUpdateAndDeleteRequireIdFilter() async {
        let rec = Recorder()
        let c = client(rec)
        await expectError("K9O_INVALID_FIELD_VALUE", contains: "update()") {
            _ = try await c.from("posts").update(["a": K9OJSON.null]).eq("status", "x").execute()
        }
        await expectError("K9O_INVALID_FIELD_VALUE", contains: "delete()") { _ = try await c.from("posts").delete().execute() }
        XCTAssertEqual(rec.count, 0)
    }

    func testMissingProjectAndBadCollection() async {
        let rec = Recorder()
        await expectError("K9O_MISSING_PROJECT_CONTEXT") {
            _ = try await makeClient(okTransport(rec), slug: nil).from("posts").select().execute()
        }
        await expectError("K9O_INVALID_FIELD_VALUE", contains: "Posts") {
            _ = try await self.client(rec).from("Posts").select().execute()
        }
        XCTAssertEqual(rec.count, 0)
    }

    // MARK: text search

    func testTextSearchWireShape() async throws {
        let rec = Recorder()
        _ = try await client(rec).from("articles").select().textSearch("body", "climate resilience").limit(5).execute()
        XCTAssertEqual(rec.query, ["textSearch": "body:climate resilience", "limit": "5"])
        XCTAssertTrue(rec.url.contains("textSearch=body%3Aclimate+resilience"), rec.url)
    }

    func testTextSearchLanguageAndTypeOnlyWhenNotDefault() async throws {
        let rec = Recorder()
        _ = try await client(rec).from("articles").select()
            .textSearch("body", "klima", language: "german", type: .websearch).execute()
        XCTAssertEqual(rec.query, ["textSearch": "body:klima", "textSearchLanguage": "german", "textSearchType": "websearch"])
        _ = try await client(rec).from("articles").select()
            .textSearch("body", "x", language: "english", type: .plain).execute()
        XCTAssertEqual(rec.query, ["textSearch": "body:x"])
    }

    func testTextSearchValidation() async {
        let c = client(Recorder())
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try c.from("a").select().textSearch("bad col", "q") }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try c.from("a").select().textSearch("1abc", "q") }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try c.from("a").select().textSearch("body", "") }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try c.from("a").select().textSearch("body", "q", language: "en-us") }
        await expectError("K9O_INVALID_FIELD_VALUE") {
            _ = try c.from("a").select().textSearch(String(repeating: "a", count: 64), "q")
        }
    }

    // MARK: vector search

    func testVectorSearchWireShape() async throws {
        let rec = Recorder()
        _ = try await client(rec).from("docs").select().vectorSearch("embedding", [0.1, 0.25, 1]).execute()
        XCTAssertEqual(rec.query, ["vectorSearch": "embedding:[0.1,0.25,1]"])
        _ = try await client(rec).from("docs").select()
            .vectorSearch("embedding", [1, 2], metric: .dot, limit: 3).execute()
        XCTAssertEqual(rec.query, ["vectorSearch": "embedding:[1,2]", "vectorMetric": "dot", "vectorLimit": "3"])
        _ = try await client(rec).from("docs").select()
            .vectorSearch("embedding", [1], metric: .euclidean).execute()
        XCTAssertEqual(rec.query["vectorMetric"], "euclidean")
    }

    func testVectorSearchValidation() async {
        let c = client(Recorder())
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try c.from("a").select().vectorSearch("emb;", [1]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try c.from("a").select().vectorSearch("emb", []) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try c.from("a").select().vectorSearch("emb", [.nan]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try c.from("a").select().vectorSearch("emb", [1], limit: 0) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try c.from("a").select().vectorSearch("emb", [1], limit: 1001) }
        _ = try? c.from("a").select().vectorSearch("emb", [1], limit: 1000)
    }

    // MARK: search

    func testSearchWireShape() async throws {
        let rec = Recorder()
        let r = try await client(rec, json: ["data": [["id": "a"]], "meta": ["cursor": ["next": "n"]]])
            .search("articles", column: "body", q: "climate", language: "french", type: .phrase, limit: 10, cursor: "c0")
        XCTAssertEqual(rec.last.httpMethod, "GET")
        XCTAssertEqual(rec.path, "/@tasks-app/data/articles")
        XCTAssertEqual(rec.query, ["textSearch": "body:climate", "textSearchLanguage": "french",
                                   "textSearchType": "phrase", "limit": "10", "cursor": "c0"])
        XCTAssertEqual(r.nextCursor, "n")
    }

    func testSearchDefaultsAndValidation() async {
        let rec = Recorder()
        let c = client(rec)
        _ = try? await c.search("articles", column: "body", q: "x")
        XCTAssertEqual(rec.query, ["textSearch": "body:x"])
        let before = rec.count
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await c.search("articles", column: "body", q: "") }
        XCTAssertEqual(rec.count, before)
    }
}
