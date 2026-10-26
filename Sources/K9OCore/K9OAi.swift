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

/// Token counts the model server reported for an inference call.
public struct K9OInferenceUsage: Decodable, Sendable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int
}

/// Result of `ai.generate`.
public struct K9OInferenceResult: Decodable, Sendable, Equatable {
    public let modelId: String
    /// The generated text.
    public let content: String
    public let finishReason: String?
    public let usage: K9OInferenceUsage
    public let usageType: String?
}

private struct InferenceBody: Encodable {
    let prompt: String
    let model: String?
    let maxTokens: Int?
    let temperature: Double?

    private enum CodingKeys: String, CodingKey { case prompt, model, maxTokens, temperature }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(prompt, forKey: .prompt)
        if let model { try c.encode(model, forKey: .model) }  // omitted when nil
        if let maxTokens { try c.encode(maxTokens, forKey: .maxTokens) }  // omitted when nil
        if let temperature { try c.encode(temperature, forKey: .temperature) }
    }
}

public struct K9OAi: Sendable {
    let client: K9OCoreClient

    /// `POST /@<projectSlug>/ai/generate` — run one inference call.
    ///
    /// `model` is optional: when nil the org's default LLM is used, and the gateway answers 400
    /// `K9O_INVALID_FIELD_VALUE` if the org has none. `maxTokens` (1 to 32000) and `temperature`
    /// (0 to 2) are sent flat in the body; every nil field is omitted. Callable by a project
    /// author or admin token, or an extension's token. Models served by an external provider
    /// answer 501 `K9O_NOT_IMPLEMENTED` until that provider is built. The prompt never appears in errors.
    /// Throws `K9O_MISSING_PROJECT_CONTEXT` (no request sent) when the client has no `projectSlug`.
    public func generate(_ prompt: String, model: String? = nil, maxTokens: Int? = nil,
                         temperature: Double? = nil) async throws -> K9OEnvelope<K9OInferenceResult> {
        guard let slug = client.projectSlug, !slug.isEmpty else {
            throw K9OError(code: K9OError.missingProjectContext,
                           message: "ai operations require projectSlug bound on the client")
        }
        return try await client.post(path: "/@\(slug)/ai/generate",
                                     body: InferenceBody(prompt: prompt, model: model, maxTokens: maxTokens,
                                                         temperature: temperature),
                                     as: K9OInferenceResult.self)
    }

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
