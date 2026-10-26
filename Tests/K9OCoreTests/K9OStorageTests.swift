import XCTest
@testable import K9OCore

final class K9OStorageTests: XCTestCase {
    private let bucketJson: [String: Any] = [
        "name": "avatars", "public": false, "fileSizeLimit": 1024, "allowedMimeTypes": ["image/png"],
        "versioning": false, "deleteAfterDays": NSNull(), "createdAt": "2026-10-26T00:00:00Z",
        "updatedAt": "2026-10-26T00:00:00Z", "system": false, "byosBindingId": NSNull(),
    ]

    func testListAndGetBuckets() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope([bucketJson])))
        let l = try await c.storage.listBuckets()
        XCTAssertEqual(rec.last.httpMethod, "GET")
        XCTAssertEqual(rec.path, "/@tasks-app/storage/buckets")
        XCTAssertEqual(l.data.first?.name, "avatars")
        XCTAssertEqual(l.data.first?.isPublic, false)
        XCTAssertEqual(l.data.first?.fileSizeLimit, 1024)
        XCTAssertNil(l.data.first?.deleteAfterDays)

        let c2 = makeClient(okTransport(rec, json: envelope(bucketJson)))
        _ = try await c2.storage.getBucket("my bucket")
        XCTAssertEqual(rec.path, "/@tasks-app/storage/buckets/my%20bucket")
    }

    func testCreateBucketBody() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope(bucketJson)))
        _ = try await c.storage.createBucket("avatars")
        XCTAssertEqual(rec.last.httpMethod, "POST")
        XCTAssertEqual(rec.path, "/@tasks-app/storage/buckets")
        XCTAssertEqual(rec.lastBody as? [String: String], ["name": "avatars"])
        _ = try await c.storage.createBucket("avatars", options: .init(isPublic: true, fileSizeLimit: 10,
                                                                      allowedMimeTypes: ["image/png"], byosBindingId: "b1"))
        let b = rec.lastBody
        XCTAssertEqual(b["public"] as? Bool, true)
        XCTAssertEqual(b["fileSizeLimit"] as? Int, 10)
        XCTAssertEqual(b["allowedMimeTypes"] as? [String], ["image/png"])
        XCTAssertEqual(b["byosBindingId"] as? String, "b1")
        XCTAssertNil(b["versioning"])
    }

    func testUpdateBucketPatchAndClear() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope(bucketJson)))
        _ = try await c.storage.updateBucket("avatars", options: .init(isPublic: false, fileSizeLimit: .clear,
                                                                      allowedMimeTypes: .set(["a/b"]), byosBindingId: .clear))
        XCTAssertEqual(rec.last.httpMethod, "PATCH")
        XCTAssertEqual(rec.path, "/@tasks-app/storage/buckets/avatars")
        let b = rec.lastBody
        XCTAssertTrue(b["fileSizeLimit"] is NSNull)
        XCTAssertTrue(b["byosBindingId"] is NSNull)
        XCTAssertEqual(b["allowedMimeTypes"] as? [String], ["a/b"])
        XCTAssertEqual(b["public"] as? Bool, false)
        XCTAssertNil(b["deleteAfterDays"])
    }

    func testDeleteBucket() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope(["name": "avatars", "deleted": true, "objectsDeleted": 3])))
        let r = try await c.storage.deleteBucket("avatars", empty: true)
        XCTAssertEqual(rec.last.httpMethod, "DELETE")
        XCTAssertEqual(rec.path, "/@tasks-app/storage/buckets/avatars")
        XCTAssertEqual(rec.query, ["empty": "true"])
        XCTAssertEqual(r.data.objectsDeleted, 3)
        _ = try await c.storage.deleteBucket("avatars")
        XCTAssertNil(rec.last.url?.query)
    }

    func testBucketNameValidation() async {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope(bucketJson)))
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await c.storage.getBucket("") }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await c.storage.getBucket("..") }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await c.storage.from(".").list() }
        await expectError("K9O_MISSING_PROJECT_CONTEXT") {
            _ = try await makeClient(okTransport(rec), slug: nil).storage.listBuckets()
        }
        XCTAssertEqual(rec.count, 0)
    }

    func testUploadIsMultipart() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope(["path": "a/b.txt", "size": 5, "lastModified": NSNull()])))
        let r = try await c.storage.from("docs").upload("a/b.txt", data: Data("hello".utf8), contentType: "text/plain",
                                                       upsert: true, metadata: ["k": "v"])
        XCTAssertEqual(rec.last.httpMethod, "POST")
        XCTAssertEqual(rec.path, "/@tasks-app/storage/buckets/docs/objects")
        let ct = rec.last.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(ct.hasPrefix("multipart/form-data; boundary="), ct)
        let body = rec.lastBodyText
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"b.txt\""), body)
        XCTAssertTrue(body.contains("Content-Type: text/plain\r\n\r\nhello\r\n"), body)
        XCTAssertTrue(body.contains("name=\"path\"\r\n\r\na/b.txt\r\n"), body)
        XCTAssertTrue(body.contains("name=\"contentType\"\r\n\r\ntext/plain\r\n"), body)
        XCTAssertTrue(body.contains("name=\"upsert\"\r\n\r\ntrue\r\n"), body)
        XCTAssertTrue(body.contains("name=\"metadata\"\r\n\r\n{\"k\":\"v\"}\r\n"), body)
        let boundary = String(ct.dropFirst("multipart/form-data; boundary=".count))
        XCTAssertTrue(body.hasSuffix("--\(boundary)--\r\n"))
        XCTAssertEqual(r.data.size, 5)
    }

    func testUploadDefaultsAndEmptyPath() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope(["path": "x", "size": 1, "lastModified": "t"])))
        _ = try await c.storage.from("docs").upload("x", data: Data([1]))
        let body = rec.lastBodyText
        XCTAssertTrue(body.contains("name=\"upsert\"\r\n\r\nfalse\r\n"))
        XCTAssertFalse(body.contains("name=\"contentType\""))
        XCTAssertFalse(body.contains("name=\"metadata\""))
        let before = rec.count
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await c.storage.from("docs").upload("", data: Data()) }
        XCTAssertEqual(rec.count, before)
    }

    func testSignedUrl() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope(["signedUrl": "https://x/y", "expiresIn": 900])))
        let r = try await c.storage.from("docs").createSignedUrl("a.png", expiresIn: 3600, download: true)
        XCTAssertEqual(rec.last.httpMethod, "POST")
        XCTAssertEqual(rec.path, "/@tasks-app/storage/buckets/docs/objects/sign")
        let b = rec.lastBody
        XCTAssertEqual(b["path"] as? String, "a.png")
        XCTAssertEqual(b["expiresIn"] as? Int, 3600)
        XCTAssertEqual(b["download"] as? Bool, true)
        XCTAssertEqual(r.data.expiresIn, 900)
        _ = try await c.storage.from("docs").createSignedUrl("a.png", expiresIn: 60)
        XCTAssertNil(rec.lastBody["download"])
    }

    func testSignedUrlValidation() async {
        let rec = Recorder()
        let c = makeClient(okTransport(rec))
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await c.storage.from("d").createSignedUrl("a", expiresIn: 0) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await c.storage.from("d").createSignedUrl("a", expiresIn: 604_801) }
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await c.storage.from("d").createSignedUrl("", expiresIn: 60) }
        XCTAssertEqual(rec.count, 0)
    }

    func testListAndRemoveObjects() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope([["path": "a/1.txt", "size": 1, "lastModified": NSNull()]])))
        let l = try await c.storage.from("docs").list(prefix: "a/")
        XCTAssertEqual(rec.last.httpMethod, "GET")
        XCTAssertEqual(rec.path, "/@tasks-app/storage/buckets/docs/objects")
        XCTAssertEqual(rec.query, ["prefix": "a/"])
        XCTAssertEqual(l.data.first?.path, "a/1.txt")
        _ = try await c.storage.from("docs").list()
        XCTAssertNil(rec.last.url?.query)

        let c2 = makeClient(okTransport(rec, json: envelope(["bucket": "docs", "path": "a b.txt", "deleted": true])))
        let r = try await c2.storage.from("docs").remove("a b.txt")
        XCTAssertEqual(rec.last.httpMethod, "DELETE")
        XCTAssertEqual(rec.path, "/@tasks-app/storage/buckets/docs/objects")
        XCTAssertEqual(rec.query, ["path": "a b.txt"])
        XCTAssertTrue(r.data.deleted)
        await expectError("K9O_INVALID_FIELD_VALUE") { _ = try await c2.storage.from("docs").remove("") }
    }
}
