import Foundation
import KilnModels

/// What a Kiln read can fail with, sorted by what the caller should do about
/// it (docs/native-apps.md, "When to restart with `initial=true`").
public enum KilnError: Error, Equatable, Sendable {
    /// `400 invalid_cursor`: the only reason to restart a sync with
    /// `initial=true`.
    case invalidCursor
    /// `503` (`artifact_compiling`, `temporarily_unavailable`) or `429`:
    /// retry the same request, after `retryAfter` seconds when the server
    /// said so.
    case retryLater(retryAfter: TimeInterval?, code: String?)
    /// `404`: an unknown type on `/api/sync`, or no such document.
    case notFound
    /// Any other HTTP status.
    case http(status: Int, code: String?)
    /// No response at all: offline, timed out, DNS. Retry with backoff.
    case transport(String)
}

/// The result of a conditional read: either the server's `304`, or a body
/// with the `ETag` to send next time.
public enum Fetched<Value: Sendable>: Sendable {
    case notModified
    case fresh(Value, etag: String?)
}

public enum SyncRequest: Equatable, Sendable {
    case initial(type: String?, limit: Int)
    case resume(cursor: String)
}

/// One page of `GET /api/sync`.
public struct SyncPage: Decodable, Sendable {
    public let items: [SyncItem]
    public let cursor: String
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case items, cursor
        case hasMore = "has_more"
    }
}

public struct SyncItem: Decodable, Sendable {
    public enum Op: String, Decodable, Sendable { case upsert, delete }

    public let op: Op
    public let type: String
    public let id: String
    /// Upserts only; a delete carries its id and type and nothing else.
    public let slug: String?
    /// The same body `GET /api/content/:type/:slug` serves. Kept as JSON so
    /// the mirror holds every key, including ones this build has no model for.
    public let artifact: JSONValue?
}

/// A minimal client for the two reads a native app needs. Anonymous on
/// purpose: a credential makes every response `private, no-store` and reads
/// drafts, so it never belongs in an app binary.
public struct KilnClient: Sendable {
    public let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Sync

    public func syncPage(_ request: SyncRequest) async throws -> SyncPage {
        var query: [URLQueryItem]
        switch request {
        case .initial(let type, let limit):
            query = [URLQueryItem(name: "initial", value: "true"), URLQueryItem(name: "limit", value: String(limit))]
            if let type { query.append(URLQueryItem(name: "type", value: type)) }
        case .resume(let cursor):
            // The cursor carries its own scope; `type` and `limit` beside it
            // are ignored, so don't send them.
            query = [URLQueryItem(name: "cursor", value: cursor)]
        }

        let (data, response) = try await send(url("api/sync", query: query), etag: nil)
        guard response.statusCode == 200 else { throw error(for: response, data: data) }
        return try JSONDecoder().decode(SyncPage.self, from: data)
    }

    // MARK: One document

    /// `GET /api/content/:type/:slug?surface=json`, revalidated with
    /// `If-None-Match` when `etag` is given. `fields` asks for a fieldset
    /// (`?fields=`); it is sent in its canonical spelling, so every install
    /// shares one CDN cache entry.
    public func document(type: String, slug: String, fields: [String]? = nil, etag: String? = nil) async throws -> Fetched<Data> {
        var query = [URLQueryItem(name: "surface", value: "json")]
        if let fields { query.append(URLQueryItem(name: "fields", value: Self.canonicalFields(fields))) }

        let path = "api/content/\(Self.segment(type))/\(Self.segment(slug))"
        let (data, response) = try await send(url(path, query: query), etag: etag)

        switch response.statusCode {
        case 304: return .notModified
        case 200: return .fresh(data, etag: response.value(forHTTPHeaderField: "ETag"))
        default: throw error(for: response, data: data)
        }
    }

    /// `?fields=` as the server's `x-kiln-fields` header spells it: sorted,
    /// de-duplicated, without `id`/`type` (always kept anyway).
    public static func canonicalFields(_ fields: [String]) -> String {
        Set(fields).subtracting(["id", "type"]).sorted().joined(separator: ",")
    }

    /// Media URLs in an artifact are site-relative (`/uploads/…`) unless the
    /// site serves media from a CDN; resolve either against the base URL.
    public func resolve(_ reference: String?) -> URL? {
        guard let reference, !reference.isEmpty else { return nil }
        return URL(string: reference, relativeTo: baseURL)?.absoluteURL
    }

    // MARK: Plumbing

    private func url(_ path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        return components.url!
    }

    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    private func send(_ url: URL, etag: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag {
            // We revalidate ourselves, so let the 304 through rather than
            // have URLCache turn it into its stored 200.
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw KilnError.transport("not an HTTP response") }
            return (data, http)
        } catch let error as KilnError {
            throw error
        } catch {
            throw KilnError.transport(error.localizedDescription)
        }
    }

    private struct Envelope: Decodable {
        struct Entry: Decodable { let code: String? }
        let errors: [Entry]
    }

    private func error(for response: HTTPURLResponse, data: Data) -> KilnError {
        let code = (try? JSONDecoder().decode(Envelope.self, from: data))?.errors.first?.code
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)

        switch (response.statusCode, code) {
        case (400, "invalid_cursor"): return .invalidCursor
        case (503, _), (429, _): return .retryLater(retryAfter: retryAfter, code: code)
        case (404, _): return .notFound
        default: return .http(status: response.statusCode, code: code)
        }
    }
}

extension JSONValue {
    /// Decode a stored artifact into a generated model.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}
