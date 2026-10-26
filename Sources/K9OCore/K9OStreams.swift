import Foundation

/// A user stream, as the gateway returns it.
public struct K9OStream: Decodable, Sendable, Equatable {
    public let id: String
    public let slug: String
    public let projectId: String
    public let displayName: String
    public let subjectPrefix: String
    public let region: String
    public let retentionSeconds: Int
    public let retentionClass: String
    public let maxBytes: Int?
    public let status: String
    public let createdAt: String
    public let createdBy: String?
}

/// One event on a stream.
public struct K9OStreamEvent: Decodable, Sendable, Equatable {
    /// The event's position in the stream.
    public let sequence: String
    /// The full subject the event was published under.
    public let subject: String
    /// The published payload.
    public let data: K9OJSON
    public let publishedAt: String

    private enum CodingKeys: String, CodingKey { case sequence, subject, data, publishedAt }

    public init(sequence: String, subject: String, data: K9OJSON, publishedAt: String) {
        self.sequence = sequence
        self.subject = subject
        self.data = data
        self.publishedAt = publishedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .sequence) { sequence = s }
        else if let n = try? c.decode(Int.self, forKey: .sequence) { sequence = String(n) }
        else { sequence = "" }
        subject = (try? c.decode(String.self, forKey: .subject)) ?? ""
        data = try c.decode(K9OJSON.self, forKey: .data)
        publishedAt = (try? c.decode(String.self, forKey: .publishedAt)) ?? ""
    }

    /// Decodes `data` into your own type.
    public func decodeData<T: Decodable>(as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(data))
    }
}

public struct K9OPublishResult: Decodable, Sendable, Equatable {
    public let streamSlug: String
    public let subject: String
    public let bytes: Int
    public let accepted: Bool
}

public struct K9OReplayResult: Decodable, Sendable, Equatable {
    public let streamSlug: String
    public let events: [K9OStreamEvent]
    /// The sequence to pass as `fromSequence` for the next page, or nil when the stream is empty.
    public let nextCursor: String?
    /// True when the page is full: there may be more events.
    public let hasMore: Bool
}

public struct K9ODeletedStream: Decodable, Sendable, Equatable {
    public let slug: String
    public let status: String
}

private struct CreateStreamBody: Encodable {
    let displayName: String
    let maxBytes: Int
    let retentionSeconds: Int?
    private enum K: String, CodingKey { case displayName, maxBytes, retentionSeconds }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(maxBytes, forKey: .maxBytes)
        try c.encodeIfPresent(retentionSeconds, forKey: .retentionSeconds)
    }
}

private struct PublishBody: Encodable {
    let data: any Encodable
    let subject: String?
    private enum K: String, CodingKey { case data, subject }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(AnyEncodable(data), forKey: .data)
        try c.encodeIfPresent(subject, forKey: .subject)
    }
}

private struct ReplayBody: Encodable {
    let fromSequence: String?
    let untilSequence: String?
    let limit: Int?
    private enum K: String, CodingKey { case fromSequence, untilSequence, limit }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encodeIfPresent(fromSequence, forKey: .fromSequence)
        try c.encodeIfPresent(untilSequence, forKey: .untilSequence)
        try c.encodeIfPresent(limit, forKey: .limit)
    }
}

/// User data streams (`/@<projectSlug>/data-streams/user`). Publishing needs project admin; subscribe and replay
/// need project admin or auditor. `K9O_STREAM_UNAVAILABLE` (503) means the stream data plane is not available in
/// this deployment, `K9O_STREAM_INVALID` means the request was refused (for example a bad subject).
/// A sequence is the stream's own position number, sent as a string; `fromSequence` is exclusive.
public struct K9OStreams: Sendable {
    let client: K9OCoreClient

    func path(_ slug: String?, _ tail: String = "") throws -> String {
        let project = try client.requireProject("streams operations")
        let s = slug.map { "/" + K9OCoreClient.segmentEncode($0) } ?? ""
        return "/@\(project)/data-streams/user\(s)\(tail)"
    }

    /// `POST /data-streams/user`. `displayName` is 1 to 80 characters; `maxBytes` is the reserved storage ceiling
    /// (1, 2, 4, 8, 16, 32 or 64 GiB); `retentionSeconds` is in whole hours (3600 or more), default 24 hours.
    public func create(displayName: String, maxBytes: Int, retentionSeconds: Int? = nil) async throws -> K9OEnvelope<K9OStream> {
        try await client.send(method: "POST", path: try path(nil),
                              body: .json(CreateStreamBody(displayName: displayName, maxBytes: maxBytes,
                                                           retentionSeconds: retentionSeconds)), as: K9OStream.self)
    }

    /// `GET /data-streams/user`: the project's active streams.
    public func list() async throws -> K9OEnvelope<[K9OStream]> {
        try await client.send(method: "GET", path: try path(nil), as: [K9OStream].self)
    }

    /// `GET /data-streams/user/<slug>`
    public func get(_ slug: String) async throws -> K9OEnvelope<K9OStream> {
        try await client.send(method: "GET", path: try path(slug), as: K9OStream.self)
    }

    /// `DELETE /data-streams/user/<slug>`: retire a stream. It reads as absent afterwards.
    public func delete(_ slug: String) async throws -> K9OEnvelope<K9ODeletedStream> {
        try await client.send(method: "DELETE", path: try path(slug), as: K9ODeletedStream.self)
    }

    /// `POST /data-streams/user/<slug>/publish`: append an event. `data` is any JSON value (`K9OJSON.null` for none).
    /// `subject` is a routing suffix of up to 8 dot-separated tokens of `[a-z0-9_-]`, each 1 to 64 characters.
    public func publish(_ slug: String, data: some Encodable, subject: String? = nil) async throws -> K9OEnvelope<K9OPublishResult> {
        try await client.send(method: "POST", path: try path(slug, "/publish"),
                              body: .json(PublishBody(data: data, subject: subject)), as: K9OPublishResult.self)
    }

    /// `POST /data-streams/user/<slug>/replay`: read a bounded range of events. `limit` is 1 to 10000 (default 100).
    public func replay(_ slug: String, fromSequence: String? = nil, untilSequence: String? = nil,
                       limit: Int? = nil) async throws -> K9OEnvelope<K9OReplayResult> {
        try await client.send(method: "POST", path: try path(slug, "/replay"),
                              body: .json(ReplayBody(fromSequence: fromSequence, untilSequence: untilSequence, limit: limit)),
                              as: K9OReplayResult.self)
    }

    /// `GET /data-streams/user/<slug>/subscribe` (Server-Sent Events): tail a stream live.
    ///
    /// Returns an async sequence of events. The connection reopens by itself after the last sequence received
    /// whenever the server closes it. The sequence ends when you stop iterating or cancel the task; a non-2xx
    /// answer (for example 503) ends it by throwing. Throws `K9O_MISSING_PROJECT_CONTEXT` when the client has no
    /// `projectSlug`.
    public func subscribe(_ slug: String, fromSequence: String? = nil) throws -> AsyncThrowingStream<K9OStreamEvent, Error> {
        let target = try path(slug, "/subscribe")
        let client = self.client
        return AsyncThrowingStream { continuation in
            let task = Task {
                var cursor = fromSequence
                var delayMs = 1000
                do {
                    while !Task.isCancelled {
                        let request = try await client.makeRequest(
                            method: "GET", path: target,
                            query: cursor.map { [("fromSequence", $0)] } ?? [], accept: "text/event-stream", body: nil)
                        let chunks: AsyncThrowingStream<Data, Error>
                        let response: URLResponse
                        do {
                            (chunks, response) = try await client.streamTransport(request)
                        } catch {
                            if Task.isCancelled { break }
                            throw K9OError(code: K9OError.upstreamUnavailable,
                                           message: "Network failure: \(error.localizedDescription)")
                        }
                        guard let http = response as? HTTPURLResponse else {
                            throw K9OError(code: K9OError.upstreamUnavailable, message: "No HTTP response")
                        }
                        guard (200...299).contains(http.statusCode) else {
                            var body = Data()
                            for try await c in chunks { body.append(c) }
                            throw K9OError.fromResponse(status: http.statusCode, data: body)
                        }
                        var parser = K9OSSEParser()
                        func handle(_ frames: [K9OSSEFrame]) {
                            for f in frames {
                                if let r = f.retry { delayMs = min(r, 30_000) }
                                guard let text = f.data,
                                      var event = try? JSONDecoder().decode(K9OStreamEvent.self, from: Data(text.utf8))
                                else { continue }
                                if let id = f.id {
                                    event = K9OStreamEvent(sequence: id, subject: event.subject, data: event.data,
                                                           publishedAt: event.publishedAt)
                                }
                                if !event.sequence.isEmpty { cursor = event.sequence }
                                continuation.yield(event)
                            }
                        }
                        do {
                            for try await chunk in chunks {
                                if Task.isCancelled { break }
                                handle(parser.feed(chunk))
                            }
                            handle(parser.finish())
                        } catch {
                            // A break in the connection is treated like the server closing it.
                            if Task.isCancelled { break }
                        }
                        if Task.isCancelled { break }
                        try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
