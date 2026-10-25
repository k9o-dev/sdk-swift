import Foundation

/// Input to `ai.embed`: one string stays a string on the wire; many is an array.
public enum K9OEmbedInput: Sendable, Equatable, Encodable {
    case one(String)
    case many([String])

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .one(let s): try c.encode(s)
        case .many(let a): try c.encode(a)
        }
    }
}

public struct K9OEmbedResult: Decodable, Sendable, Equatable {
    /// One vector per input string, in input order.
    public let embeddings: [[Double]]
    public let model: String
    public let dimensions: Int
}

private struct EmbedBody: Encodable {
    let model: String?
    let input: K9OEmbedInput

    private enum CodingKeys: String, CodingKey { case model, input }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let model { try c.encode(model, forKey: .model) }  // omitted when nil
        try c.encode(input, forKey: .input)
    }
}

public struct K9OAi: Sendable {
    let client: K9OCoreClient

    /// `POST /@<projectSlug>/ai/embeddings` — embed one or more strings.
    ///
    /// The gateway refuses an end user's token; callable by a project member's
    /// or an extension's token only. Input bounds are enforced by the server,
    /// not here; the input is sent exactly as given and never appears in errors.
    /// Throws `K9O_MISSING_PROJECT_CONTEXT` (no request sent) when the client
    /// has no `projectSlug`.
    public func embed(model: String? = nil, input: K9OEmbedInput) async throws -> K9OEnvelope<K9OEmbedResult> {
        guard let slug = client.projectSlug, !slug.isEmpty else {
            throw K9OError(code: K9OError.missingProjectContext,
                           message: "ai operations require projectSlug bound on the client")
        }
        return try await client.post(path: "/@\(slug)/ai/embeddings",
                                     body: EmbedBody(model: model, input: input),
                                     as: K9OEmbedResult.self)
    }
}
