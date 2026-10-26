import Foundation

/// Success envelope `{ data, meta }`. `meta` is empty when absent.
public struct K9OEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    public let data: T
    public let meta: [String: K9OJSON]

    private enum CodingKeys: String, CodingKey { case data, meta }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decode(T.self, forKey: .data)
        meta = (try? c.decodeIfPresent([String: K9OJSON].self, forKey: .meta)) ?? [:]
    }
}

/// Transport: performs one request. Injectable for tests; defaults to `URLSession`.
public typealias K9OTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// Streaming transport: opens one request and yields the response body in chunks as they arrive.
/// Injectable for tests; defaults to `URLSession`'s byte stream.
public typealias K9OStreamTransport = @Sendable (URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse)

private let defaultStreamTransport: K9OStreamTransport = { req in
    let (bytes, response) = try await URLSession.shared.bytes(for: req)
    let stream = AsyncThrowingStream<Data, Error> { continuation in
        let task = Task {
            do {
                var chunk = Data()
                for try await b in bytes {
                    chunk.append(b)
                    if b == 0x0A { continuation.yield(chunk); chunk = Data() }
                }
                if !chunk.isEmpty { continuation.yield(chunk) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
    return (stream, response)
}

/// Project-plane core client.
public final class K9OCoreClient: Sendable {
    let baseURL: URL
    let projectSlug: String?
    let tokenProvider: (@Sendable () async throws -> String?)?
    let transport: K9OTransport
    let streamTransport: K9OStreamTransport

    /// - Parameters:
    ///   - baseURL: org API origin, e.g. `https://acme.api.k9o.io`.
    ///   - projectSlug: the `@<slug>` project; required by project-plane calls.
    ///   - accessToken: static Bearer token (ignored when `tokenProvider` is given).
    ///   - tokenProvider: called per request for the Bearer token.
    ///   - transport: injectable HTTP transport.
    ///   - streamTransport: injectable transport for `streams.subscribe`.
    public init(
        baseURL: URL,
        projectSlug: String? = nil,
        accessToken: String? = nil,
        tokenProvider: (@Sendable () async throws -> String?)? = nil,
        transport: K9OTransport? = nil,
        streamTransport: K9OStreamTransport? = nil
    ) {
        self.baseURL = baseURL
        self.projectSlug = projectSlug
        if let tokenProvider {
            self.tokenProvider = tokenProvider
        } else if let accessToken {
            self.tokenProvider = { accessToken }
        } else {
            self.tokenProvider = nil
        }
        self.transport = transport ?? { req in try await URLSession.shared.data(for: req) }
        self.streamTransport = streamTransport ?? defaultStreamTransport
    }

    /// Platform AI primitives.
    public var ai: K9OAi { K9OAi(client: self) }

    /// Object storage: buckets and the objects in them.
    public var storage: K9OStorage { K9OStorage(client: self) }

    /// User data streams (Pulse): create, publish, replay and subscribe.
    public var streams: K9OStreams { K9OStreams(client: self) }

    /// Start a data query on a collection: `from("posts").select()`, `.insert(...)`, `.update(...)`, `.delete()`.
    public func from(_ collection: String) -> K9OFrom { K9OFrom(client: self, collection: collection) }

    // MARK: internal HTTP

    func post<B: Encodable, R: Decodable & Sendable>(
        path: String, body: B, as: R.Type
    ) async throws -> K9OEnvelope<R> {
        try await send(method: "POST", path: path, body: .json(body), as: R.self)
    }

    /// Request body: JSON-encoded, or raw bytes with their own content type (multipart uploads).
    enum Body {
        case json(any Encodable)
        case raw(Data, contentType: String)
    }

    /// Percent-encodes one query component the way a browser's `URLSearchParams` does (space becomes `+`).
    static func formEncode(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2A, 0x2D, 0x2E, 0x5F: out.append(Character(UnicodeScalar(b)))
            case 0x20: out.append("+")
            default: out.append(String(format: "%%%02X", b))
            }
        }
        return out
    }

    /// Percent-encodes one path segment (like `encodeURIComponent`).
    static func segmentEncode(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x21, 0x27, 0x28, 0x29, 0x2A, 0x2D, 0x2E, 0x5F, 0x7E:
                out.append(Character(UnicodeScalar(b)))
            default: out.append(String(format: "%%%02X", b))
            }
        }
        return out
    }

    func makeRequest(method: String, path: String, query: [(String, String)], accept: String,
                     body: Body?) async throws -> URLRequest {
        var base = baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        var text = base + (path.hasPrefix("/") ? path : "/" + path)
        if !query.isEmpty {
            text += "?" + query.map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }.joined(separator: "&")
        }
        guard let url = URL(string: text) else {
            throw K9OError(code: K9OError.internalError, message: "Failed to build request URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("k9o-core-swift/0.1.0", forHTTPHeaderField: "User-Agent")
        if let tokenProvider, let token = try await tokenProvider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        switch body {
        case .none: break
        case .json(let value):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONEncoder().encode(AnyEncodable(value))
            } catch {
                throw K9OError(code: K9OError.internalError, message: "Failed to encode request body")
            }
        case .raw(let data, let contentType):
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        }
        return request
    }

    func send<R: Decodable & Sendable>(
        method: String, path: String, query: [(String, String)] = [], body: Body? = nil, as: R.Type
    ) async throws -> K9OEnvelope<R> {
        let request = try await makeRequest(method: method, path: path, query: query,
                                            accept: "application/json", body: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            // Deliberately not interpolating the request; only the transport's own description.
            throw K9OError(code: K9OError.upstreamUnavailable,
                           message: "Network failure: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw K9OError(code: K9OError.upstreamUnavailable, message: "No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw K9OError.fromResponse(status: http.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(K9OEnvelope<R>.self, from: data)
        } catch {
            throw K9OError(code: K9OError.internalError,
                           message: "Malformed success response (HTTP \(http.statusCode))",
                           status: http.statusCode)
        }
    }

    func requireProject(_ what: String) throws -> String {
        guard let slug = projectSlug, !slug.isEmpty else {
            throw K9OError(code: K9OError.missingProjectContext,
                           message: "\(what) require projectSlug bound on the client")
        }
        return slug
    }
}

struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

extension K9OEnvelope {
    /// The cursor for the next page (`meta.cursor.next`), or nil on the last page.
    public var nextCursor: String? {
        if case .object(let c)? = meta["cursor"], case .string(let n)? = c["next"] { return n }
        return nil
    }
}
