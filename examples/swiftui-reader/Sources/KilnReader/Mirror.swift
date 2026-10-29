import Foundation
import KilnModels

/// Everything the app keeps between launches: the mirrored documents and the
/// cursor that says how far they go. Saved as one value, so a page's items
/// and its cursor are always written together.
public struct MirrorState: Codable, Equatable, Sendable {
    public var cursor: String?
    /// Keyed by document `id`.
    public var documents: [String: StoredDocument]
    /// Set while an `initial=true` restart runs over data we kept: the ids
    /// the new snapshot has sent so far. When the snapshot ends, every
    /// document not in it is deleted. Persisted, so a restart cut short by
    /// the OS resumes rather than forgetting what it has seen.
    public var snapshotSeen: Set<String>?
    /// When the last complete snapshot finished, for the occasional full resync.
    public var lastSnapshotAt: Date?

    public init(cursor: String? = nil, documents: [String: StoredDocument] = [:], snapshotSeen: Set<String>? = nil, lastSnapshotAt: Date? = nil) {
        self.cursor = cursor
        self.documents = documents
        self.snapshotSeen = snapshotSeen
        self.lastSnapshotAt = lastSnapshotAt
    }
}

public struct StoredDocument: Codable, Equatable, Sendable {
    public var type: String
    public var slug: String?
    public var artifact: JSONValue
    /// The `ETag` of the last single-document read, for `If-None-Match`.
    /// Cleared when sync replaces the artifact.
    public var etag: String?

    public init(type: String, slug: String?, artifact: JSONValue, etag: String? = nil) {
        self.type = type
        self.slug = slug
        self.artifact = artifact
        self.etag = etag
    }
}

public protocol MirrorStore: Sendable {
    func load() throws -> MirrorState
    func save(_ state: MirrorState) throws
}

/// A JSON file, replaced atomically on every save (write to a temporary
/// file, then rename), so a kill mid-write leaves the previous page's state.
/// Fine for a few thousand documents; a bigger mirror wants SwiftData or
/// SQLite with the same rule: one transaction per page, cursor included.
public struct FileMirrorStore: MirrorStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func `default`() throws -> FileMirrorStore {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SwiftUIReader", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return FileMirrorStore(url: dir.appendingPathComponent("mirror.json"))
    }

    public func load() throws -> MirrorState {
        guard FileManager.default.fileExists(atPath: url.path) else { return MirrorState() }
        return try JSONDecoder().decode(MirrorState.self, from: Data(contentsOf: url))
    }

    public func save(_ state: MirrorState) throws {
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}
