import KilnModels
@testable import KilnReader
import XCTest

/// The sync loop against a stubbed `URLProtocol`: what it requests, what it
/// stores after each page, and when it restarts, retries or gives up.
final class SyncEngineTests: XCTestCase {
    var store: FileMirrorStore!
    var sleeps: SleepLog!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = FileMirrorStore(url: dir.appendingPathComponent("mirror.json"))
        sleeps = SleepLog()
        Stub.reset()
    }

    func engine(maxAttempts: Int = 5) -> SyncEngine {
        var backoff = Backoff()
        backoff.maxAttempts = maxAttempts
        backoff.jitter = { 1 }
        let sleeps = sleeps!
        return SyncEngine(client: Stub.client(), store: store, type: "recipe", backoff: backoff, sleep: { await sleeps.record($0) })
    }

    // MARK: First sync and deltas

    func testAFirstSyncFollowsTheCursorAndSavesEveryPage() async throws {
        Stub.enqueue(.json(page([upsert("a"), upsert("b")], cursor: "c1", hasMore: true)))
        Stub.enqueue(.json(page([upsert("c")], cursor: "c2", hasMore: false)))

        let outcome = try await engine().run()

        XCTAssertEqual(outcome, SyncOutcome(pages: 2, upserts: 3, deletes: 0, restarted: false))
        XCTAssertEqual(Stub.queries(), [
            ["initial": "true", "limit": "500", "type": "recipe"],
            // A cursor carries its own scope: nothing else beside it.
            ["cursor": "c1"],
        ])
        let state = try store.load()
        XCTAssertEqual(state.cursor, "c2")
        XCTAssertEqual(Set(state.documents.keys), ["a", "b", "c"])
        XCTAssertNotNil(state.lastSnapshotAt)
    }

    /// The cursor is stored with the page it covers: a sync cut short
    /// resumes from the last saved page, not from `initial=true`.
    func testAnInterruptedSyncResumesFromTheLastSavedPage() async throws {
        Stub.enqueue(.json(page([upsert("a")], cursor: "c1", hasMore: true)))
        Stub.enqueue(.error(status: 404, code: "not_found"))

        await XCTAssertThrowsErrorAsync(try await self.engine().run()) { XCTAssertEqual($0 as? KilnError, .notFound) }
        let state = try store.load()
        XCTAssertEqual(state.cursor, "c1")
        XCTAssertEqual(Array(state.documents.keys), ["a"])

        Stub.enqueue(.json(page([upsert("b")], cursor: "c2", hasMore: false)))
        try await engine().run()
        XCTAssertEqual(Stub.queries().last, ["cursor": "c1"])
        XCTAssertEqual(try store.load().cursor, "c2")
    }

    func testADeltaAppliesTheCapturedDeletion() async throws {
        let delta = try JSONDecoder().decode(SyncPage.self, from: fixture("sync-delta-page"))
        let deleted = try XCTUnwrap(delta.items.first { $0.op == .delete }).id
        try store.save(MirrorState(cursor: "stored", documents: [deleted: doc(deleted), "kept": doc("kept")]))
        Stub.enqueue(.json(try fixture("sync-delta-page")))

        let outcome = try await engine().run()

        XCTAssertEqual(outcome.deletes, 1)
        XCTAssertEqual(Stub.queries(), [["cursor": "stored"]])
        let state = try store.load()
        XCTAssertNil(state.documents[deleted])
        XCTAssertNotNil(state.documents["kept"])
        XCTAssertEqual(state.cursor, delta.cursor)
    }

    func testADeleteForAnUnknownIdAndARepeatedUpsertAreHarmless() async throws {
        try store.save(MirrorState(cursor: "c0", documents: ["a": doc("a")]))
        Stub.enqueue(.json(page([upsert("a"), upsert("a"), delete("never-held")], cursor: "c1", hasMore: false)))

        try await engine().run()
        XCTAssertEqual(Array(try store.load().documents.keys), ["a"])
    }

    // MARK: invalid_cursor

    /// Only `invalid_cursor` restarts. Local data is kept through the new
    /// snapshot, and what the snapshot didn't send is deleted at its end.
    func testARefusedCursorRestartsKeepingDataUntilTheSnapshotEnds() async throws {
        try store.save(MirrorState(cursor: "rotated", documents: ["a": doc("a"), "stale": doc("stale")]))
        let store = store!

        Stub.enqueue(.error(status: 400, code: "invalid_cursor"))
        Stub.enqueue(.json(page([upsert("a")], cursor: "n1", hasMore: true)))
        Stub.enqueue(.inspect {
            // Mid-snapshot: the page is stored, nothing is deleted yet.
            let state = try! store.load()
            XCTAssertEqual(state.cursor, "n1")
            XCTAssertEqual(Set(state.documents.keys), ["a", "stale"])
            XCTAssertEqual(state.snapshotSeen, ["a"])
            return .json(self.page([self.upsert("b")], cursor: "n2", hasMore: false))
        })

        let outcome = try await engine().run()

        XCTAssertTrue(outcome.restarted)
        XCTAssertEqual(Stub.queries(), [
            ["cursor": "rotated"],
            ["initial": "true", "limit": "500", "type": "recipe"],
            ["cursor": "n1"],
        ])
        let state = try store.load()
        XCTAssertEqual(Set(state.documents.keys), ["a", "b"])
        XCTAssertNil(state.snapshotSeen)
        XCTAssertEqual(state.cursor, "n2")
    }

    /// A restart cut short keeps its record of what the snapshot has sent,
    /// so the next wake still deletes the right documents.
    func testAnInterruptedRestartStillDeletesWhatTheSnapshotDidNotSend() async throws {
        try store.save(MirrorState(cursor: "rotated", documents: ["a": doc("a"), "stale": doc("stale")]))
        Stub.enqueue(.error(status: 400, code: "invalid_cursor"))
        Stub.enqueue(.json(page([upsert("a")], cursor: "n1", hasMore: true)))
        Stub.enqueue(.error(status: 404, code: "not_found"))
        await XCTAssertThrowsErrorAsync(try await self.engine().run())

        Stub.enqueue(.json(page([upsert("b")], cursor: "n2", hasMore: false)))
        try await engine().run()

        XCTAssertEqual(Set(try store.load().documents.keys), ["a", "b"])
    }

    // MARK: Retries

    func testA503RetriesTheSameRequestAfterRetryAfter() async throws {
        try store.save(MirrorState(cursor: "c0"))
        Stub.enqueue(.error(status: 503, code: "artifact_compiling", retryAfter: "7"))
        Stub.enqueue(.json(page([upsert("a")], cursor: "c1", hasMore: false)))

        let outcome = try await engine().run()

        XCTAssertFalse(outcome.restarted)
        XCTAssertEqual(Stub.queries(), [["cursor": "c0"], ["cursor": "c0"]])
        let waits = await sleeps.waits
        XCTAssertEqual(waits, [7])
    }

    func testNetworkErrorsBackOffExponentially() async throws {
        Stub.enqueue(.failure(URLError(.notConnectedToInternet)))
        Stub.enqueue(.failure(URLError(.timedOut)))
        Stub.enqueue(.error(status: 429, code: "rate_limited"))
        Stub.enqueue(.json(page([], cursor: "c1", hasMore: false)))

        try await engine().run()
        let waits = await sleeps.waits
        XCTAssertEqual(waits, [2, 4, 8])
    }

    /// After a handful of attempts the wake gives up; the stored cursor
    /// hasn't moved, so the next wake retries the same page.
    func testGivesUpForThisWakeWithTheCursorUnmoved() async throws {
        try store.save(MirrorState(cursor: "c0", documents: ["a": doc("a")]))
        for _ in 0..<3 { Stub.enqueue(.error(status: 503, code: "temporarily_unavailable")) }

        await XCTAssertThrowsErrorAsync(try await self.engine(maxAttempts: 3).run()) {
            XCTAssertEqual($0 as? KilnError, .retryLater(retryAfter: nil, code: "temporarily_unavailable"))
        }
        XCTAssertEqual(Stub.queries().count, 3)
        XCTAssertEqual(try store.load(), MirrorState(cursor: "c0", documents: ["a": doc("a")]))
    }

    func testAnUnknownTypeIsNotRetriedOrRestarted() async throws {
        try store.save(MirrorState(cursor: "c0"))
        Stub.enqueue(.error(status: 404, code: "not_found"))

        await XCTAssertThrowsErrorAsync(try await self.engine().run())
        XCTAssertEqual(Stub.queries().count, 1)
        XCTAssertEqual(try store.load().cursor, "c0")
    }

    func testBackoffIsCappedAndJittered() {
        var backoff = Backoff()
        backoff.jitter = { 0.5 }
        XCTAssertEqual(backoff.delay(attempt: 1, retryAfter: nil), 1)
        XCTAssertEqual(backoff.delay(attempt: 20, retryAfter: nil), 90)
        XCTAssertEqual(backoff.delay(attempt: 3, retryAfter: 30), 30)
    }

    // MARK: One document

    func testADocumentReadRevalidatesWithIfNoneMatch() async throws {
        let client = Stub.client()
        Stub.enqueue(.json(try fixture("recipe-artifact"), etag: #"W/"abc""#))
        Stub.enqueue(.status(304))

        guard case .fresh(let data, let etag) = try await client.document(type: "recipe", slug: "buttermilk-pancakes") else {
            return XCTFail("expected a body")
        }
        XCTAssertEqual(try Recipe(data: data).document.slug, "buttermilk-pancakes")
        XCTAssertEqual(etag, #"W/"abc""#)

        guard case .notModified = try await client.document(type: "recipe", slug: "buttermilk-pancakes", etag: etag) else {
            return XCTFail("expected 304")
        }
        XCTAssertEqual(Stub.requests().map { $0.value(forHTTPHeaderField: "If-None-Match") }, [nil, #"W/"abc""#])
        XCTAssertEqual(Stub.requests().first?.url?.path, "/api/content/recipe/buttermilk-pancakes")
        XCTAssertEqual(Stub.queries().first, ["surface": "json"])
    }

    func testFieldsAreSentInTheirCanonicalSpelling() async throws {
        Stub.enqueue(.json(try fixture("recipe-fields")))
        _ = try await Stub.client().document(type: "recipe", slug: "x", fields: ["title", "slug", "id", "title", "custom_fields.hero"])

        XCTAssertEqual(Stub.queries(), [["surface": "json", "fields": "custom_fields.hero,slug,title"]])
    }

    // MARK: Helpers

    func doc(_ id: String) -> StoredDocument {
        StoredDocument(type: "recipe", slug: id, artifact: .object(["id": .string(id), "type": .string("recipe")]))
    }

    func upsert(_ id: String) -> [String: Any] {
        ["op": "upsert", "type": "recipe", "id": id, "slug": id, "artifact": ["id": id, "type": "recipe"]]
    }

    func delete(_ id: String) -> [String: Any] { ["op": "delete", "type": "recipe", "id": id] }

    func page(_ items: [[String: Any]], cursor: String, hasMore: Bool) -> Data {
        try! JSONSerialization.data(withJSONObject: ["items": items, "cursor": cursor, "has_more": hasMore])
    }
}

actor SleepLog {
    var waits: [TimeInterval] = []
    func record(_ seconds: TimeInterval) { waits.append(seconds) }
}

func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath, line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}

/// Canned responses, served in order, with every request recorded.
final class Stub: URLProtocol {
    enum Response {
        case json(Data, etag: String? = nil)
        case error(status: Int, code: String, retryAfter: String? = nil)
        case status(Int)
        case failure(URLError)
        case inspect(() -> Response)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Response] = []
    nonisolated(unsafe) private static var seen: [URLRequest] = []

    static func reset() { lock.withLock { queue = []; seen = [] } }
    static func enqueue(_ response: Response) { lock.withLock { queue.append(response) } }
    static func requests() -> [URLRequest] { lock.withLock { seen } }

    static func queries() -> [[String: String]] {
        requests().map { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        }
    }

    static func client() -> KilnClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return KilnClient(baseURL: URL(string: "http://kiln.test")!, session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let next: Response? = Stub.lock.withLock {
            Stub.seen.append(request)
            return Stub.queue.isEmpty ? nil : Stub.queue.removeFirst()
        }
        guard var response = next else { return fail(URLError(.resourceUnavailable)) }
        while case .inspect(let make) = response { response = make() }

        switch response {
        case .json(let data, let etag):
            respond(200, data, etag.map { ["ETag": $0] } ?? [:])
        case .error(let status, let code, let retryAfter):
            let body = try! JSONSerialization.data(withJSONObject: ["errors": [["status": String(status), "code": code, "detail": ""]]])
            respond(status, body, retryAfter.map { ["Retry-After": $0] } ?? [:])
        case .status(let status):
            respond(status, Data(), [:])
        case .failure(let error):
            fail(error)
        case .inspect:
            fatalError("unreachable")
        }
    }

    private func respond(_ status: Int, _ body: Data, _ headers: [String: String]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }
}
