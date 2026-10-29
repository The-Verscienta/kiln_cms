import Foundation
import KilnModels

/// Exponential backoff with jitter (docs/native-apps.md, "Backoff"):
/// `Retry-After` when the server sent one, otherwise 2 s, 4 s, 8 s … capped,
/// each multiplied by a random factor in 0.5…1.5 so a fleet of phones waking
/// together doesn't retry in lockstep.
public struct Backoff: Sendable {
    public var base: TimeInterval = 2
    public var cap: TimeInterval = 180
    /// Attempts per request in one wake, the first included. After that the
    /// wake gives up; the stored cursor hasn't moved, so nothing is lost.
    public var maxAttempts = 5
    public var jitter: @Sendable () -> Double = { Double.random(in: 0.5...1.5) }

    public init() {}

    /// The wait before retry number `attempt` (1 = the first retry).
    public func delay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter { return retryAfter }
        return min(cap, base * pow(2, Double(attempt - 1))) * jitter()
    }
}

public struct SyncOutcome: Equatable, Sendable {
    public var pages = 0
    public var upserts = 0
    public var deletes = 0
    /// The stored cursor was refused and the mirror was rebuilt from
    /// `initial=true`.
    public var restarted = false
}

/// Keeps a `MirrorStore` current from `GET /api/sync`, following
/// docs/native-apps.md "Mirroring with sync":
///
/// - one atomic save per page, the page's items and its cursor together;
/// - restart with `initial=true` only on `400 invalid_cursor`, keeping local
///   data until the new snapshot ends and then deleting what it didn't send;
/// - every other failure retries the same request with backoff, and gives up
///   for this wake after `Backoff.maxAttempts`.
public actor SyncEngine {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    let client: KilnClient
    let store: MirrorStore
    let type: String?
    let limit: Int
    let backoff: Backoff
    let sleep: Sleep

    /// `type` scopes the mirror to one content type (`nil` = every public
    /// type). `limit` defaults to 500, the maximum: fewer requests matter
    /// more than smaller ones when users share an IP behind carrier NAT.
    public init(
        client: KilnClient,
        store: MirrorStore,
        type: String?,
        limit: Int = 500,
        backoff: Backoff = Backoff(),
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.client = client
        self.store = store
        self.type = type
        self.limit = limit
        self.backoff = backoff
        self.sleep = sleep
    }

    /// One sync: the first snapshot, or a delta from the stored cursor,
    /// following `has_more` to the end. Call it on launch, on returning to
    /// the foreground and from a `BGAppRefreshTask`.
    @discardableResult
    public func run() async throws -> SyncOutcome {
        var state = try store.load()
        var outcome = SyncOutcome()
        var snapshot = state.cursor == nil || state.snapshotSeen != nil

        while true {
            let request: SyncRequest = state.cursor.map { .resume(cursor: $0) } ?? .initial(type: type, limit: limit)

            let page: SyncPage
            do {
                page = try await fetch(request)
            } catch KilnError.invalidCursor where state.cursor != nil {
                // Signed with a rotated SECRET_KEY_BASE, another site's, or
                // altered. Start over, but keep what we have: a refused
                // cursor says nothing about which documents are still live.
                state.cursor = nil
                state.snapshotSeen = []
                try store.save(state)
                outcome.restarted = true
                snapshot = true
                continue
            }

            apply(page, to: &state, outcome: &outcome)
            if snapshot && !page.hasMore { state.lastSnapshotAt = Date() }
            try store.save(state)
            outcome.pages += 1

            if !page.hasMore { return outcome }
        }
    }

    /// The periodic full resync the guide recommends (weekly, on Wi-Fi):
    /// some changes, like a fragment edit, re-fire a document without
    /// reporting it. Runs a fresh snapshot over the kept data.
    @discardableResult
    public func resync() async throws -> SyncOutcome {
        var state = try store.load()
        state.cursor = nil
        state.snapshotSeen = []
        try store.save(state)
        return try await run()
    }

    /// Store a newer artifact read through `GET /api/content` (a detail
    /// screen's refresh) with its `ETag`. The cursor is untouched: a later
    /// delta re-sending the same document is harmless.
    public func store(id: String, type: String, slug: String?, artifact: JSONValue, etag: String?) throws {
        var state = try store.load()
        state.documents[id] = StoredDocument(type: type, slug: slug, artifact: artifact, etag: etag)
        try store.save(state)
    }

    // MARK: -

    private func apply(_ page: SyncPage, to state: inout MirrorState, outcome: inout SyncOutcome) {
        // In order, keyed by id. Applying an item twice is harmless, and a
        // delete for an id we don't hold is normal.
        for item in page.items {
            switch item.op {
            case .upsert:
                guard let artifact = item.artifact else { continue }
                state.documents[item.id] = StoredDocument(type: item.type, slug: item.slug, artifact: artifact)
                state.snapshotSeen?.insert(item.id)
                outcome.upserts += 1
            case .delete:
                state.documents[item.id] = nil
                state.snapshotSeen?.remove(item.id)
                outcome.deletes += 1
            }
        }

        state.cursor = page.cursor

        if !page.hasMore {
            if let seen = state.snapshotSeen {
                state.documents = state.documents.filter { seen.contains($0.key) }
                state.snapshotSeen = nil
            }
        }
    }

    private func fetch(_ request: SyncRequest) async throws -> SyncPage {
        var attempt = 0
        while true {
            do {
                return try await client.syncPage(request)
            } catch let error as KilnError {
                attempt += 1
                let retryAfter: TimeInterval?
                switch error {
                case .retryLater(let after, _): retryAfter = after
                case .transport: retryAfter = nil
                // invalid_cursor, 404 and anything else: not ours to retry.
                default: throw error
                }
                guard attempt < backoff.maxAttempts else { throw error }
                try await sleep(backoff.delay(attempt: attempt, retryAfter: retryAfter))
            }
        }
    }
}
