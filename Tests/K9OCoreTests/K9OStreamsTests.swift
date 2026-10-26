import XCTest
@testable import K9OCore

private let streamJson: [String: Any] = [
    "id": "s1", "slug": "orders", "projectId": "p1", "displayName": "Orders", "subjectPrefix": "p1.orders",
    "region": "de01", "retentionSeconds": 86400, "retentionClass": "standard", "maxBytes": 1_073_741_824,
    "status": "active", "createdAt": "2026-10-26T00:00:00Z", "createdBy": NSNull(),
]

final class K9OStreamsTests: XCTestCase {
    func testCreate() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope(streamJson)))
        let r = try await c.streams.create(displayName: "Orders", maxBytes: 1_073_741_824)
        XCTAssertEqual(rec.last.httpMethod, "POST")
        XCTAssertEqual(rec.path, "/@tasks-app/data-streams/user")
        XCTAssertEqual(rec.lastBody["displayName"] as? String, "Orders")
        XCTAssertEqual(rec.lastBody["maxBytes"] as? Int, 1_073_741_824)
        XCTAssertNil(rec.lastBody["retentionSeconds"])
        XCTAssertEqual(r.data.slug, "orders")
        XCTAssertNil(r.data.createdBy)
        _ = try await c.streams.create(displayName: "Orders", maxBytes: 1, retentionSeconds: 7200)
        XCTAssertEqual(rec.lastBody["retentionSeconds"] as? Int, 7200)
    }

    func testListGetDelete() async throws {
        let rec = Recorder()
        let l = try await makeClient(okTransport(rec, json: envelope([streamJson]))).streams.list()
        XCTAssertEqual(rec.last.httpMethod, "GET")
        XCTAssertEqual(rec.path, "/@tasks-app/data-streams/user")
        XCTAssertEqual(l.data.count, 1)

        _ = try await makeClient(okTransport(rec, json: envelope(streamJson))).streams.get("orders")
        XCTAssertEqual(rec.last.httpMethod, "GET")
        XCTAssertEqual(rec.path, "/@tasks-app/data-streams/user/orders")

        let d = try await makeClient(okTransport(rec, json: envelope(["slug": "orders", "status": "retired"]))).streams.delete("orders")
        XCTAssertEqual(rec.last.httpMethod, "DELETE")
        XCTAssertEqual(rec.path, "/@tasks-app/data-streams/user/orders")
        XCTAssertEqual(d.data.status, "retired")
    }

    func testPublish() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, status: 202,
                                       json: envelope(["streamSlug": "orders", "subject": "p1.orders.new", "bytes": 12, "accepted": true])))
        let r = try await c.streams.publish("orders", data: ["id": K9OJSON.number(7)], subject: "new")
        XCTAssertEqual(rec.last.httpMethod, "POST")
        XCTAssertEqual(rec.path, "/@tasks-app/data-streams/user/orders/publish")
        XCTAssertEqual((rec.lastBody["data"] as? [String: Int]), ["id": 7])
        XCTAssertEqual(rec.lastBody["subject"] as? String, "new")
        XCTAssertTrue(r.data.accepted)

        _ = try await c.streams.publish("orders", data: K9OJSON.null)
        XCTAssertTrue(rec.lastBody["data"] is NSNull)
        XCTAssertNil(rec.lastBody["subject"])
        _ = try await c.streams.publish("orders", data: "plain text")
        XCTAssertEqual(rec.lastBody["data"] as? String, "plain text")
    }

    func testReplay() async throws {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, json: envelope([
            "streamSlug": "orders",
            "events": [["sequence": "5", "subject": "p1.orders.new", "data": ["id": 1], "publishedAt": "t"],
                       ["sequence": 6, "subject": "p1.orders.new", "data": "x", "publishedAt": "t"]],
            "nextCursor": "6", "hasMore": false,
        ])))
        let r = try await c.streams.replay("orders", fromSequence: "4", untilSequence: "9", limit: 50)
        XCTAssertEqual(rec.last.httpMethod, "POST")
        XCTAssertEqual(rec.path, "/@tasks-app/data-streams/user/orders/replay")
        XCTAssertEqual(rec.lastBody["fromSequence"] as? String, "4")
        XCTAssertEqual(rec.lastBody["untilSequence"] as? String, "9")
        XCTAssertEqual(rec.lastBody["limit"] as? Int, 50)
        XCTAssertEqual(r.data.events.map(\.sequence), ["5", "6"])
        XCTAssertEqual(r.data.events[0].data, .object(["id": .number(1)]))
        XCTAssertEqual(r.data.nextCursor, "6")
        XCTAssertFalse(r.data.hasMore)
        _ = try await c.streams.replay("orders")
        XCTAssertEqual(rec.lastBody.count, 0)
    }

    func testDecodeEventData() throws {
        struct Order: Decodable, Equatable { let id: Int }
        let e = K9OStreamEvent(sequence: "1", subject: "s", data: .object(["id": .number(3)]), publishedAt: "t")
        XCTAssertEqual(try e.decodeData(as: Order.self), Order(id: 3))
    }

    func testSlugIsPathEncodedAndProjectRequired() async {
        let rec = Recorder()
        _ = try? await makeClient(okTransport(rec, json: envelope(streamJson))).streams.get("a/b")
        XCTAssertEqual(rec.path, "/@tasks-app/data-streams/user/a%2Fb")
        await expectError("K9O_MISSING_PROJECT_CONTEXT") { _ = try await makeClient(okTransport(rec), slug: nil).streams.list() }
        XCTAssertThrowsError(try makeClient(okTransport(rec), slug: nil).streams.subscribe("orders")) {
            XCTAssertEqual(($0 as? K9OError)?.code, "K9O_MISSING_PROJECT_CONTEXT")
        }
    }

    func testStreamErrorSurfaces() async {
        let rec = Recorder()
        let c = makeClient(okTransport(rec, status: 503, json: ["code": "K9O_STREAM_UNAVAILABLE", "message": "no data plane"]))
        await expectError("K9O_STREAM_UNAVAILABLE") { _ = try await c.streams.list() }
    }

    // MARK: SSE parser

    func testSSEParserHandlesSplitChunksAndControlFields() {
        var p = K9OSSEParser()
        var frames: [K9OSSEFrame] = []
        for chunk in [": hb\n\nretry: 5", "0\n\nid: 3\ndata: {\"a\"", ":1}\n\nda", "ta: x\n", "data: y\r\n\r\n"] {
            frames += p.feed(Data(chunk.utf8))
        }
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[0], K9OSSEFrame(id: nil, event: nil, data: nil, retry: 50))
        XCTAssertEqual(frames[0].retry, 50)
        XCTAssertEqual(frames[1].id, "3")
        XCTAssertEqual(frames[1].data, "{\"a\":1}")
        XCTAssertEqual(frames[2].data, "x\ny")
        XCTAssertEqual(p.feed(Data("data: tail".utf8)), [])
        XCTAssertEqual(p.finish().first?.data, "tail")
    }

    // MARK: subscribe

    private func sse(_ events: [(String, String)], retry: Int? = nil) -> Data {
        var s = retry.map { "retry: \($0)\n\n" } ?? ""
        for (seq, payload) in events { s += "id: \(seq)\ndata: \(payload)\n\n" }
        return Data(s.utf8)
    }

    private func event(_ seq: String, _ value: Int) -> String {
        "{\"sequence\":\"\(seq)\",\"subject\":\"p1.orders.new\",\"data\":{\"n\":\(value)},\"publishedAt\":\"t\"}"
    }

    func testSubscribeYieldsEventsAndReconnectsAfterLastSequence() async throws {
        let rec = Recorder()
        let calls = Counter()
        let first = sse([("5", event("5", 1)), ("6", event("6", 2))], retry: 1)
        let second = sse([("7", event("7", 3))])
        let stream: K9OStreamTransport = { req in
            rec.requests.append(req)
            let n = calls.next()
            let data = n == 0 ? first : second
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
            let s = AsyncThrowingStream<Data, Error> { c in
                c.yield(data.prefix(data.count / 2))        // split mid-frame
                c.yield(data.suffix(from: data.count / 2))
                if n == 0 { c.finish() }                    // server closes the first connection; the second stays open
            }
            return (s, resp)
        }
        let client = makeClient(okTransport(rec), stream: stream)
        var got: [K9OStreamEvent] = []
        for try await e in try client.streams.subscribe("orders", fromSequence: "4") {
            got.append(e)
            if got.count == 3 { break }
        }
        XCTAssertEqual(got.map(\.sequence), ["5", "6", "7"])
        XCTAssertEqual(got[0].data, .object(["n": .number(1)]))
        XCTAssertEqual(rec.requests.count, 2)
        XCTAssertEqual(rec.requests[0].httpMethod, "GET")
        XCTAssertEqual(rec.requests[0].value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(rec.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tok_abc")
        XCTAssertEqual(rec.requests[0].url?.absoluteString, "https://acme.api.k9o.io/@tasks-app/data-streams/user/orders/subscribe?fromSequence=4")
        XCTAssertEqual(rec.requests[1].url?.absoluteString, "https://acme.api.k9o.io/@tasks-app/data-streams/user/orders/subscribe?fromSequence=6")
    }

    func testSubscribeStartsFromBeginningWithoutSequence() async throws {
        let rec = Recorder()
        let stream: K9OStreamTransport = { req in
            rec.requests.append(req)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (AsyncThrowingStream { c in c.yield(self.sse([("1", self.event("1", 1))])) }, resp)
        }
        for try await _ in try makeClient(okTransport(rec), stream: stream).streams.subscribe("orders") { break }
        XCTAssertEqual(rec.requests[0].url?.absoluteString, "https://acme.api.k9o.io/@tasks-app/data-streams/user/orders/subscribe")
    }

    func testSubscribeNon2xxThrowsStreamError() async {
        let rec = Recorder()
        let stream: K9OStreamTransport = { req in
            rec.requests.append(req)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (AsyncThrowingStream { c in
                c.yield(Data("{\"code\":\"K9O_STREAM_UNAVAILABLE\",\"message\":\"down\"}".utf8))
                c.finish()
            }, resp)
        }
        await expectError("K9O_STREAM_UNAVAILABLE") {
            for try await _ in try makeClient(okTransport(rec), stream: stream).streams.subscribe("orders") {}
        }
        XCTAssertEqual(rec.requests.count, 1)
    }

    func testSubscribeSkipsNonEventFrames() async throws {
        let rec = Recorder()
        let payload = "data: not json\n\ndata: {\"x\":1}\n\n" + "id: 9\ndata: \(event("9", 5))\n\n"
        let stream: K9OStreamTransport = { req in
            rec.requests.append(req)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (AsyncThrowingStream { c in c.yield(Data(payload.utf8)) }, resp)
        }
        for try await e in try makeClient(okTransport(rec), stream: stream).streams.subscribe("orders") {
            XCTAssertEqual(e.sequence, "9")
            break
        }
    }
}

final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n - 1 }
}
