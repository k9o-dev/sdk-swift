import XCTest
@testable import K9OCore

final class K9OQueryTests: XCTestCase {
    // MARK: shared translation vectors

    private func translate(_ sql: String, _ named: [String: K9OValue]) throws -> (String, [K9OValue]) {
        let r = try K9OQueryTranslator.translate(sql, named: named)
        return (r.sql, r.params)
    }

    func testVector1() throws {
        let (sql, p) = try translate("SELECT * FROM users WHERE data->>'role' = :role", ["role": "admin"])
        XCTAssertEqual(sql, "SELECT * FROM users WHERE data->>'role' = $1")
        XCTAssertEqual(p, ["admin"])
    }

    func testVector2() throws {
        let (sql, p) = try translate("SELECT :a, :b, :a", ["a": 1, "b": 2])
        XCTAssertEqual(sql, "SELECT $1, $2, $1")
        XCTAssertEqual(p, [1, 2])
    }

    func testVector3() throws {
        let (sql, p) = try translate(#"SELECT ':not_a_param', ":also_not", x::int FROM t WHERE y = :y"#, ["y": true])
        XCTAssertEqual(sql, #"SELECT ':not_a_param', ":also_not", x::int FROM t WHERE y = $1"#)
        XCTAssertEqual(p, [true])
    }

    func testVector4() throws {
        let (sql, p) = try translate("SELECT 'it''s :no' , :v -- :comment\nFROM t", ["v": nil])
        XCTAssertEqual(sql, "SELECT 'it''s :no' , $1 -- :comment\nFROM t")
        XCTAssertEqual(p, [.null])
    }

    func testVector5() throws {
        let (sql, p) = try translate("SELECT /* :c /* :d */ :e */ :f", ["f": 1])
        XCTAssertEqual(sql, "SELECT /* :c /* :d */ :e */ $1")
        XCTAssertEqual(p, [1])
    }

    func testVector6() throws {
        let (sql, p) = try translate("SELECT $$ :x $$, $q$ :y $q$, :z", ["z": "s"])
        XCTAssertEqual(sql, "SELECT $$ :x $$, $q$ :y $q$, $1")
        XCTAssertEqual(p, ["s"])
    }

    func testVector7() throws {
        let (sql, p) = try translate("SELECT arr[1:2], a:b, :n", ["n": 5])
        XCTAssertEqual(sql, "SELECT arr[1:2], a:b, $1")
        XCTAssertEqual(p, [5])
    }

    func testVector8MissingValueThrowsBeforeAnyRequest() async {
        let rec = Recorder()
        let c = makeClient(okTransport(rec))
        await expectError("K9O_INVALID_FIELD_VALUE", contains: ":missing") {
            _ = try await c.query("SELECT :missing", params: [:])
        }
        XCTAssertEqual(rec.count, 0)
    }

    /// Vector 9 (an object value) cannot be written in Swift: `K9OValue` only holds string, number, boolean and null.
    /// The remaining unbindable value, a number that is not finite, is refused the same way.
    func testVector9UnbindableValueThrows() async {
        let rec = Recorder()
        let c = makeClient(okTransport(rec))
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await c.query("SELECT :a", params: ["a": .double(.nan)]) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await c.query("SELECT $1", params: [.double(.infinity)]) }
        XCTAssertEqual(rec.count, 0)
    }

    func testVector10ListParamsSentUnchanged() async throws {
        let rec = Recorder()
        _ = try await makeClient(okTransport(rec)).query("SELECT $1", params: ["x"])
        XCTAssertEqual(rec.lastBody["sql"] as? String, "SELECT $1")
        XCTAssertEqual(rec.lastBody["params"] as? [String], ["x"])
    }

    func testListParamsAreNotTranslated() async throws {
        let rec = Recorder()
        _ = try await makeClient(okTransport(rec)).query("SELECT ':a', :a", params: [1])
        XCTAssertEqual(rec.lastBody["sql"] as? String, "SELECT ':a', :a")
    }

    func testVector11NoParamsOmitsKey() async throws {
        let rec = Recorder()
        _ = try await makeClient(okTransport(rec)).query("SELECT 1")
        XCTAssertEqual(Set(rec.lastBody.keys), ["sql"])
        let rec2 = Recorder()
        _ = try await makeClient(okTransport(rec2)).query("SELECT 1", params: [])
        XCTAssertEqual(Set(rec2.lastBody.keys), ["sql"])
    }

    func testExtraKeysIgnoredAndRepeatedNamesReuseNumber() throws {
        let (sql, p) = try translate("SELECT :b, :b", ["a": 1, "b": 2])
        XCTAssertEqual(sql, "SELECT $1, $1")
        XCTAssertEqual(p, [2])
    }

    func testEscapeStringAndQuotedIdentifier() throws {
        let (sql, _) = try translate(#"SELECT E'a\' :x', "c "" :y", :z"#, ["z": 1])
        XCTAssertEqual(sql, #"SELECT E'a\' :x', "c "" :y", $1"#)
    }

    // MARK: wire shape

    func testQueryWireShape() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: ["data": [["id": "r1", "n": 2]],
                                                   "meta": ["rawQuery": ["intent": "select", "rowCount": 1]]]))
        let r = try await c.query("SELECT * FROM users WHERE data->>'role' = :role", params: ["role": "admin"])
        XCTAssertEqual(rec.last.httpMethod, "POST")
        XCTAssertEqual(rec.url, "https://acme.api.k9o.io/@tasks-app/query")
        XCTAssertEqual(rec.last.value(forHTTPHeaderField: "Authorization"), "Bearer tok_abc")
        XCTAssertEqual(rec.last.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(rec.lastBody["sql"] as? String, "SELECT * FROM users WHERE data->>'role' = $1")
        XCTAssertEqual(rec.lastBody["params"] as? [String], ["admin"])
        XCTAssertEqual(r.data, [["id": .string("r1"), "n": .number(2)]])
        XCTAssertEqual(r.meta["rawQuery"], .object(["intent": .string("select"), "rowCount": .number(1)]))
    }

    func testParamTypesOnTheWire() async throws {
        let rec = Recorder()
        _ = try await makeClient(okTransport(rec)).query("SELECT $1,$2,$3,$4,$5", params: ["s", 3, 1.5, true, nil])
        let p = rec.lastBody["params"] as! [Any]
        XCTAssertEqual(p[0] as? String, "s")
        XCTAssertEqual(p[1] as? Int, 3)
        XCTAssertEqual(p[2] as? Double, 1.5)
        XCTAssertEqual(p[3] as? Bool, true)
        XCTAssertTrue(p[4] is NSNull)
    }

    func testQueryDecodesIntoCallerType() async throws {
        struct User: Decodable, Sendable, Equatable { let id: String }
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope([["id": "u1"]])))
        let r = try await c.query("SELECT id FROM users", as: User.self)
        XCTAssertEqual(r.data, [User(id: "u1")])
    }

    func testQueryWithoutProjectSlug() async {
        let rec = Recorder()
        await expectError("K9O_MISSING_PROJECT_CONTEXT") {
            _ = try await makeClient(okTransport(rec), slug: nil).query("SELECT 1")
        }
        XCTAssertEqual(rec.count, 0)
    }

    func testServerReadOnlyRefusalSurfaces() async {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, status: 400, json: ["code": "K9O_RAW_SQL_READ_ONLY", "message": "read only"]))
        await expectError("K9O_RAW_SQL_READ_ONLY") { _ = try await c.query("DELETE FROM t") }
    }
}
