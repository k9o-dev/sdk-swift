import Foundation

/// A bucket.
public struct K9OBucket: Decodable, Sendable, Equatable {
    public let name: String
    /// Stored and returned, not enforced: setting it does not yet change who can read objects.
    public let isPublic: Bool
    /// Bytes; nil means no limit.
    public let fileSizeLimit: Int?
    /// MIME allow-list; empty means any.
    public let allowedMimeTypes: [String]
    public let versioning: Bool
    public let deleteAfterDays: Int?
    public let createdAt: String
    public let updatedAt: String
    /// Platform-owned buckets cannot be written through the public routes.
    public let system: Bool
    /// The storage location the bucket is linked to, or nil for platform-managed storage.
    public let byosBindingId: String?

    private enum CodingKeys: String, CodingKey {
        case name, fileSizeLimit, allowedMimeTypes, versioning, deleteAfterDays, createdAt, updatedAt, system
        case byosBindingId
        case isPublic = "public"
    }
}

/// An object listing entry. `path` is relative to the bucket.
public struct K9OStorageObject: Decodable, Sendable, Equatable {
    public let path: String
    public let size: Int
    public let lastModified: String?
}

/// `expiresIn` is the lifetime the gateway used: at most 900 seconds, even when you asked for more.
public struct K9OSignedUrl: Decodable, Sendable, Equatable {
    public let signedUrl: String
    public let expiresIn: Int
}

public struct K9ORemovedObject: Decodable, Sendable, Equatable {
    public let bucket: String
    public let path: String
    public let deleted: Bool
}

public struct K9ODeletedBucket: Decodable, Sendable, Equatable {
    public let name: String
    public let deleted: Bool
    public let objectsDeleted: Int
}

/// A field of an update: `.set(value)` changes it, `.clear` sends null (removes a limit, unlinks, allows any type).
public enum K9OPatch<Value: Encodable & Sendable>: Sendable {
    case set(Value)
    case clear
}

/// Options for `createBucket`.
public struct K9OCreateBucketOptions: Sendable {
    public var isPublic: Bool?
    public var fileSizeLimit: Int?
    public var allowedMimeTypes: [String]?
    public var versioning: Bool?
    public var deleteAfterDays: Int?
    public var byosBindingId: String?

    public init(isPublic: Bool? = nil, fileSizeLimit: Int? = nil, allowedMimeTypes: [String]? = nil,
                versioning: Bool? = nil, deleteAfterDays: Int? = nil, byosBindingId: String? = nil) {
        self.isPublic = isPublic
        self.fileSizeLimit = fileSizeLimit
        self.allowedMimeTypes = allowedMimeTypes
        self.versioning = versioning
        self.deleteAfterDays = deleteAfterDays
        self.byosBindingId = byosBindingId
    }
}

/// Fields to change on a bucket; nil fields are left alone.
public struct K9OUpdateBucketOptions: Sendable {
    public var isPublic: Bool?
    public var fileSizeLimit: K9OPatch<Int>?
    public var allowedMimeTypes: K9OPatch<[String]>?
    public var versioning: Bool?
    public var deleteAfterDays: K9OPatch<Int>?
    public var byosBindingId: K9OPatch<String>?

    public init(isPublic: Bool? = nil, fileSizeLimit: K9OPatch<Int>? = nil,
                allowedMimeTypes: K9OPatch<[String]>? = nil, versioning: Bool? = nil,
                deleteAfterDays: K9OPatch<Int>? = nil, byosBindingId: K9OPatch<String>? = nil) {
        self.isPublic = isPublic
        self.fileSizeLimit = fileSizeLimit
        self.allowedMimeTypes = allowedMimeTypes
        self.versioning = versioning
        self.deleteAfterDays = deleteAfterDays
        self.byosBindingId = byosBindingId
    }
}

private struct CreateBucketBody: Encodable {
    let name: String
    let options: K9OCreateBucketOptions
    private enum K: String, CodingKey {
        case name, fileSizeLimit, allowedMimeTypes, versioning, deleteAfterDays, byosBindingId
        case isPublic = "public"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(options.isPublic, forKey: .isPublic)
        try c.encodeIfPresent(options.fileSizeLimit, forKey: .fileSizeLimit)
        try c.encodeIfPresent(options.allowedMimeTypes, forKey: .allowedMimeTypes)
        try c.encodeIfPresent(options.versioning, forKey: .versioning)
        try c.encodeIfPresent(options.deleteAfterDays, forKey: .deleteAfterDays)
        try c.encodeIfPresent(options.byosBindingId, forKey: .byosBindingId)
    }
}

private struct UpdateBucketBody: Encodable {
    let options: K9OUpdateBucketOptions
    private enum K: String, CodingKey {
        case fileSizeLimit, allowedMimeTypes, versioning, deleteAfterDays, byosBindingId
        case isPublic = "public"
    }
    private func patch<V>(_ c: inout KeyedEncodingContainer<K>, _ p: K9OPatch<V>?, _ key: K) throws {
        switch p {
        case .none: break
        case .some(.clear): try c.encodeNil(forKey: key)
        case .some(.set(let v)): try c.encode(v, forKey: key)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encodeIfPresent(options.isPublic, forKey: .isPublic)
        try patch(&c, options.fileSizeLimit, .fileSizeLimit)
        try patch(&c, options.allowedMimeTypes, .allowedMimeTypes)
        try c.encodeIfPresent(options.versioning, forKey: .versioning)
        try patch(&c, options.deleteAfterDays, .deleteAfterDays)
        try patch(&c, options.byosBindingId, .byosBindingId)
    }
}

private struct SignBody: Encodable {
    let path: String
    let expiresIn: Int
    let download: Bool?
    private enum K: String, CodingKey { case path, expiresIn, download }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(path, forKey: .path)
        try c.encode(expiresIn, forKey: .expiresIn)
        try c.encodeIfPresent(download, forKey: .download)
    }
}

private func requireObjectPath(_ path: String) throws {
    if path.isEmpty {
        throw K9OError.invalidField("object path must not be empty",
                                    context: .object(["field": .string("path"), "reason": .string("empty")]))
    }
}

/// Object storage: per-project logical buckets and the objects in them
/// (`/@<projectSlug>/storage/buckets...`). A signed PUT is not offered; uploads go through `upload`.
public struct K9OStorage: Sendable {
    let client: K9OCoreClient

    func bucketsPath() throws -> String { "/@\(try client.requireProject("storage operations"))/storage/buckets" }

    func bucketPath(_ name: String, _ suffix: String = "") throws -> String {
        let base = try bucketsPath()
        if name.isEmpty {
            throw K9OError.invalidField("bucket name must not be empty",
                                        context: .object(["field": .string("bucket"), "reason": .string("empty")]))
        }
        // "." and ".." would be collapsed as dot segments before the request leaves and address another route.
        if name == "." || name == ".." {
            throw K9OError.invalidField("bucket name must not be a dot segment",
                                        context: .object(["field": .string("bucket"), "reason": .string("dot_segment")]))
        }
        return "\(base)/\(K9OCoreClient.segmentEncode(name))\(suffix)"
    }

    /// `GET /@<projectSlug>/storage/buckets`
    public func listBuckets() async throws -> K9OEnvelope<[K9OBucket]> {
        try await client.send(method: "GET", path: try bucketsPath(), as: [K9OBucket].self)
    }

    /// `GET .../buckets/<name>`
    public func getBucket(_ name: String) async throws -> K9OEnvelope<K9OBucket> {
        try await client.send(method: "GET", path: try bucketPath(name), as: K9OBucket.self)
    }

    /// `POST .../buckets`. A name outside 3 to 63 lowercase letters, digits and hyphens is refused by the platform.
    public func createBucket(_ name: String, options: K9OCreateBucketOptions = .init()) async throws -> K9OEnvelope<K9OBucket> {
        try await client.send(method: "POST", path: try bucketsPath(),
                              body: .json(CreateBucketBody(name: name, options: options)), as: K9OBucket.self)
    }

    /// `PATCH .../buckets/<name>`
    public func updateBucket(_ name: String, options: K9OUpdateBucketOptions) async throws -> K9OEnvelope<K9OBucket> {
        try await client.send(method: "PATCH", path: try bucketPath(name),
                              body: .json(UpdateBucketBody(options: options)), as: K9OBucket.self)
    }

    /// `DELETE .../buckets/<name>`. A non-empty bucket is refused unless `empty` is true, which purges its objects first.
    public func deleteBucket(_ name: String, empty: Bool = false) async throws -> K9OEnvelope<K9ODeletedBucket> {
        try await client.send(method: "DELETE", path: try bucketPath(name),
                              query: empty ? [("empty", "true")] : [], as: K9ODeletedBucket.self)
    }

    /// A handle on one bucket for object operations: `storage.from("avatars").upload(...)`.
    public func from(_ bucket: String) -> K9OBucketHandle { K9OBucketHandle(storage: self, bucket: bucket) }
}

/// Object operations on one bucket.
public struct K9OBucketHandle: Sendable {
    let storage: K9OStorage
    let bucket: String

    /// `POST .../buckets/<bucket>/objects` (multipart). `upsert` false (the default) refuses to overwrite an
    /// existing path (409 `K9O_ALREADY_EXISTS`). `metadata` is caller-defined strings, at most 10 keys and 2 KB.
    public func upload(_ path: String, data: Data, contentType: String? = nil, upsert: Bool = false,
                       metadata: [String: String]? = nil) async throws -> K9OEnvelope<K9OStorageObject> {
        try requireObjectPath(path)
        let target = try storage.bucketPath(bucket, "/objects")
        let boundary = "k9o-\(UUID().uuidString)"
        var body = Data()
        func text(_ s: String) { body.append(Data(s.utf8)) }
        func field(_ name: String, _ value: String) {
            text("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        let filename = path.split(separator: "/").last.map(String.init) ?? "file"
        let safeName = filename.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        text("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n")
        text("Content-Type: \(contentType ?? "application/octet-stream")\r\n\r\n")
        body.append(data)
        text("\r\n")
        field("path", path)
        if let contentType { field("contentType", contentType) }
        field("upsert", upsert ? "true" : "false")
        if let metadata {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            field("metadata", String(decoding: try enc.encode(metadata), as: UTF8.self))
        }
        text("--\(boundary)--\r\n")
        return try await storage.client.send(method: "POST", path: target,
                                             body: .raw(body, contentType: "multipart/form-data; boundary=\(boundary)"),
                                             as: K9OStorageObject.self)
    }

    /// Uploads the contents of a local file.
    public func upload(_ path: String, fileURL: URL, contentType: String? = nil, upsert: Bool = false,
                       metadata: [String: String]? = nil) async throws -> K9OEnvelope<K9OStorageObject> {
        try await upload(path, data: try Data(contentsOf: fileURL), contentType: contentType, upsert: upsert,
                         metadata: metadata)
    }

    /// `POST .../objects/sign`: a pre-authenticated GET URL for one object. `expiresIn` (1 to 604800 seconds) is
    /// required, with no default; the URL lives at most 900 seconds and the answer's `expiresIn` is the lifetime used.
    public func createSignedUrl(_ path: String, expiresIn: Int, download: Bool? = nil) async throws -> K9OEnvelope<K9OSignedUrl> {
        try requireObjectPath(path)
        guard (1...604_800).contains(expiresIn) else {
            throw K9OError.invalidField("expiresIn is required and must be an integer from 1 to 604800 seconds",
                                        context: .object(["field": .string("expiresIn"), "reason": .string("out_of_range")]),
                                        recommendation: "Pass an explicit expiresIn; signed URLs have no default lifetime.")
        }
        return try await storage.client.send(method: "POST", path: try storage.bucketPath(bucket, "/objects/sign"),
                                             body: .json(SignBody(path: path, expiresIn: expiresIn, download: download)),
                                             as: K9OSignedUrl.self)
    }

    /// `GET .../objects`, optionally under a prefix.
    public func list(prefix: String? = nil) async throws -> K9OEnvelope<[K9OStorageObject]> {
        try await storage.client.send(method: "GET", path: try storage.bucketPath(bucket, "/objects"),
                                      query: prefix.map { [("prefix", $0)] } ?? [], as: [K9OStorageObject].self)
    }

    /// `DELETE .../objects?path=`: delete one object.
    public func remove(_ path: String) async throws -> K9OEnvelope<K9ORemovedObject> {
        try requireObjectPath(path)
        return try await storage.client.send(method: "DELETE", path: try storage.bucketPath(bucket, "/objects"),
                                             query: [("path", path)], as: K9ORemovedObject.self)
    }
}
