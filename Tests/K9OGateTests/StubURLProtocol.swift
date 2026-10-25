import Foundation

/// URLProtocol stub for intercepting gateway requests in tests.
/// Register a handler keyed on HTTP method + path suffix before each test.
final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (statusCode: Int, body: Data?)

    // Thread-safe stub registry keyed by "<METHOD> <path-suffix>", e.g. "POST signin"
    private static var handlers: [String: Handler] = [:]
    private static let lock = NSLock()

    static func register(method: String, pathSuffix: String, handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers["\(method.uppercased()) \(pathSuffix)"] = handler
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handlers = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        let method = request.httpMethod?.uppercased() ?? "GET"

        // Match on last path component (the "signin" / "refresh" / etc. suffix)
        let suffix = url.components(separatedBy: "/").last ?? ""
        let key = "\(method) \(suffix)"

        let handler: Handler?
        StubURLProtocol.lock.lock()
        handler = StubURLProtocol.handlers[key]
        StubURLProtocol.lock.unlock()

        if let h = handler {
            // URLSession moves the request body to `httpBodyStream`, leaving
            // `httpBody` nil inside the protocol — rehydrate it so handlers can
            // inspect the sent body (e.g. assert the refreshToken field).
            var req = request
            if req.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let bufSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                while stream.hasBytesAvailable {
                    let n = stream.read(buffer, maxLength: bufSize)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                buffer.deallocate()
                stream.close()
                req.httpBody = data
            }
            let (statusCode, body) = h(req)
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            if let data = body {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let error = URLError(.unsupportedURL)
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - JSON fixture helpers

func jsonData(_ dict: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: dict)
}

let mockUser: [String: Any] = [
    "id": "eu_TestUserABC123",
    "email": "user@example.com",
    "status": "active",
    "created_at": "2026-01-01T00:00:00Z",
    "updated_at": NSNull(),
    "last_signin_at": NSNull(),
    "roles": ["PROJECT_END_USER"],
    "groups": [],
]

let mockSession: [String: Any] = [
    "access_token": "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJldV9UZXN0VXNlckFCQzEyMyIsImV4cCI6OTk5OTk5OTk5OSwiaWF0IjoxNzAwMDAwMDAwLCJpc3MiOiJodHRwczovL2FwaS5rOW8uaW8iLCJleHQucGFydG5lcnMiOnsicGFydG5lcl9yb2xlIjoiZXh0ZW5zaW9uX29yZ19hZG1pbiJ9fQ.sig",
    "refresh_token": "rt_MockRefreshToken0001",
    "expires_at": "2099-01-01T00:00:00Z",
]

func authResultEnvelope() -> Data {
    jsonData(["data": ["user": mockUser, "session": mockSession], "meta": [:]])
}

// Matches the real gateway error body: a KError at the ROOT, with
// platform-namespaced `K9O_*` codes — NOT a `{ "error": { … } }` wrapper.
func errorEnvelope(code: String, message: String = "Error") -> Data {
    jsonData(["code": code, "message": message])
}
