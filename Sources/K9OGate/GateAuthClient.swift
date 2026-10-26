import Foundation

/// Internal HTTP transport layer for K9OGate.
///
/// Sends JSON requests to the gateway and decodes JSON responses into
/// typed envelopes. All methods are `async throws`; errors are mapped
/// to `K9OGateError` before surfacing to callers.
struct GateAuthClient {
    let baseURL: URL
    let session: URLSession
    let projectSlug: String

    /// The gateway's keys are camelCase on the wire; they pass through unchanged.
    private let decoder = JSONDecoder()

    /// Resolve the project-relative path: `<baseURL>/@<projectSlug>/gate/<suffix>`.
    /// `baseURL` is the org API origin you configured; it is used as given.
    private func url(for suffix: String) -> URL {
        let path = "/@\(projectSlug)/gate/\(suffix)"
        return baseURL.appendingPathComponent(path)
    }

    func post<B: Encodable, R: Decodable>(
        path: String,
        body: B,
        responseType: R.Type
    ) async throws -> R {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("k9o-gate-swift", forHTTPHeaderField: "User-Agent")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw K9OGateError.decoding(error)
        }
        return try await execute(request: request, responseType: responseType)
    }

    func get<R: Decodable>(path: String, bearerToken: String, responseType: R.Type) async throws -> R {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("k9o-gate-swift", forHTTPHeaderField: "User-Agent")
        return try await execute(request: request, responseType: responseType)
    }

    private func execute<R: Decodable>(request: URLRequest, responseType: R.Type) async throws -> R {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw K9OGateError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw K9OGateError.unknown(statusCode: -1, body: nil)
        }
        guard (200...299).contains(http.statusCode) else {
            throw K9OGateError.from(statusCode: http.statusCode, data: data)
        }
        do {
            let envelope = try decoder.decode(K9OEnvelope<R>.self, from: data)
            return envelope.data
        } catch {
            throw K9OGateError.decoding(error)
        }
    }
}

// MARK: - Request body shapes (internal; match the gateway OpenAPI)

struct SignInBody: Encodable {
    let email: String
    let password: String
}

/// The refresh body is closed to `{ refreshToken }`; the gateway refuses any other field.
struct RefreshTokenBody: Encodable {
    let refreshToken: String
}

struct SignOutBody: Encodable {
    let refreshToken: String
}
