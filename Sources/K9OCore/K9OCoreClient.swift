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

/// Project-plane core client.
public final class K9OCoreClient: Sendable {
    let baseURL: URL
    let projectSlug: String?
    let tokenProvider: (@Sendable () async throws -> String?)?
    let transport: K9OTransport

    /// - Parameters:
    ///   - baseURL: org API origin, e.g. `https://acme.api.k9o.io`.
    ///   - projectSlug: the `@<slug>` project; required by project-plane calls.
    ///   - accessToken: static Bearer token (ignored when `tokenProvider` is given).
    ///   - tokenProvider: called per request for the Bearer token.
    ///   - transport: injectable HTTP transport.
    public init(
        baseURL: URL,
        projectSlug: String? = nil,
        accessToken: String? = nil,
        tokenProvider: (@Sendable () async throws -> String?)? = nil,
        transport: K9OTransport? = nil
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
    }

    /// Platform AI primitives.
    public var ai: K9OAi { K9OAi(client: self) }

    // MARK: internal HTTP

    func post<B: Encodable, R: Decodable & Sendable>(
        path: String, body: B, as: R.Type
    ) async throws -> K9OEnvelope<R> {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("k9o-core-swift/0.1.0", forHTTPHeaderField: "User-Agent")
        if let tokenProvider, let token = try await tokenProvider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw K9OError(code: K9OError.internalError, message: "Failed to encode request body")
        }

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
}
