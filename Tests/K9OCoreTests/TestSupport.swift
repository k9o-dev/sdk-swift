import XCTest
@testable import K9OCore

final class Recorder: @unchecked Sendable {
    var requests: [URLRequest] = []
    var count: Int { requests.count }
    var last: URLRequest { requests[requests.count - 1] }
    var lastBody: [String: Any] {
        (try? JSONSerialization.jsonObject(with: last.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }
    var lastBodyText: String { String(decoding: last.httpBody ?? Data(), as: UTF8.self) }
    var url: String { last.url?.absoluteString ?? "" }
    var path: String { last.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? "" }
    /// Decoded query items (form-decoded: `+` is a space).
    var query: [String: String] {
        guard let raw = last.url?.query else { return [:] }
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let dec = { (s: Substring) in String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
            out[dec(kv[0])] = kv.count > 1 ? dec(kv[1]) : ""
        }
        return out
    }
}

func okTransport(_ rec: Recorder, status: Int = 200, json: Any = ["data": [], "meta": [String: Any]()]) -> K9OTransport {
    return { req in
        rec.requests.append(req)
        let data = try! JSONSerialization.data(withJSONObject: json)
        let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        return (data, resp)
    }
}

func makeClient(_ t: @escaping K9OTransport, slug: String? = "tasks-app",
                stream: K9OStreamTransport? = nil) -> K9OCoreClient {
    K9OCoreClient(baseURL: URL(string: "https://acme.api.k9o.io")!, projectSlug: slug,
                  accessToken: "tok_abc", transport: t, streamTransport: stream)
}

func envelope(_ data: Any) -> [String: Any] { ["data": data, "meta": [String: Any]()] }

func expectError(_ code: String, contains: String? = nil, file: StaticString = #filePath, line: UInt = #line,
                 _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("expected \(code)", file: file, line: line)
    } catch let e as K9OError {
        XCTAssertEqual(e.code, code, file: file, line: line)
        if let contains { XCTAssertTrue(e.message.contains(contains), "message: \(e.message)", file: file, line: line) }
    } catch {
        XCTFail("unexpected error \(error)", file: file, line: line)
    }
}
