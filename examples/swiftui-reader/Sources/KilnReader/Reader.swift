import Foundation
import KilnModels
import Observation

/// A mirrored recipe, decoded with the generated model.
public struct Recipe: Identifiable, Hashable, Sendable {
    public let document: RecipeDocument

    public var id: String { document.id }

    public init(document: RecipeDocument) {
        self.document = document
    }

    public init(artifact: JSONValue) throws {
        let data = try JSONEncoder().encode(artifact)
        try self.init(data: data)
    }

    public init(data: Data) throws {
        document = try JSONDecoder().decode(RecipeDocument.self, from: data)
    }
}

/// A list row's fieldset: `?fields=title,slug,custom_fields.hero,custom_fields.minutes`.
///
/// A fieldset response is deliberately not a valid full document (`blocks`
/// and the rest are missing), so it decodes into its own small type rather
/// than `RecipeDocument`. The media snapshot is the generated one.
public struct RecipeCard: Decodable, Hashable, Sendable {
    public static let fields = ["title", "slug", "custom_fields.hero", "custom_fields.minutes"]

    public let id: String
    public let type: String
    public let title: String?
    public let slug: String?
    public let customFields: CustomFields?

    public struct CustomFields: Decodable, Hashable, Sendable {
        public let hero: MediaSnapshot?
        public let minutes: Int?
    }

    enum CodingKeys: String, CodingKey {
        case id, type, title, slug
        case customFields = "custom_fields"
    }
}

/// The app's state: the mirror on disk, kept fresh by sync, plus the
/// "featured" card read through `?fields=` and revalidated by `ETag`.
@MainActor @Observable
public final class Reader {
    public private(set) var recipes: [Recipe] = []
    public private(set) var featured: RecipeCard?
    public private(set) var status: String?
    public private(set) var syncing = false

    public let client: KilnClient
    let engine: SyncEngine
    let store: MirrorStore
    let featuredSlug: String?
    private var featuredETag: String?

    public init(client: KilnClient, store: MirrorStore, type: String = "recipe", featuredSlug: String? = nil) {
        self.client = client
        self.store = store
        self.engine = SyncEngine(client: client, store: store, type: type)
        self.featuredSlug = featuredSlug
        reload()
    }

    /// Foreground refresh: one sync delta (the first snapshot on a fresh
    /// install), a full resync once a week, then the featured card.
    public func refresh() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        do {
            let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
            let last = (try? store.load())?.lastSnapshotAt
            let outcome = try await (last.map { $0 < weekAgo } ?? false ? engine.resync() : engine.run())
            status = "Synced: \(outcome.upserts) updated, \(outcome.deletes) removed" + (outcome.restarted ? " (restarted)" : "")
        } catch {
            status = "Sync failed: \(error). Showing saved recipes."
        }
        reload()
        await refreshFeatured()
    }

    func refreshFeatured() async {
        guard let featuredSlug else { return }
        do {
            switch try await client.document(type: "recipe", slug: featuredSlug, fields: RecipeCard.fields, etag: featuredETag) {
            case .notModified:
                break
            case .fresh(let data, let etag):
                featured = try JSONDecoder().decode(RecipeCard.self, from: data)
                featuredETag = etag
            }
        } catch {
            // Keep the last card; it's a widget, not the content.
        }
    }

    /// Pull-to-refresh on a detail screen: a conditional read of the one
    /// document. A `304` costs a few hundred bytes.
    @discardableResult
    public func revalidate(_ recipe: Recipe) async -> Recipe {
        guard let slug = recipe.document.slug else { return recipe }
        let etag = (try? store.load())?.documents[recipe.id]?.etag
        do {
            switch try await client.document(type: "recipe", slug: slug, etag: etag) {
            case .notModified:
                status = "Up to date (304)"
                return recipe
            case .fresh(let data, let newTag):
                let artifact = try JSONDecoder().decode(JSONValue.self, from: data)
                try await engine.store(id: recipe.id, type: "recipe", slug: slug, artifact: artifact, etag: newTag)
                reload()
                status = "Refreshed"
                return recipes.first { $0.id == recipe.id } ?? recipe
            }
        } catch KilnError.notFound {
            status = "This recipe is no longer published"
            return recipe
        } catch {
            status = "Couldn't refresh: \(error)"
            return recipe
        }
    }

    func reload() {
        let documents = (try? store.load())?.documents.values.filter { $0.type == "recipe" } ?? []
        recipes = documents
            .compactMap { try? Recipe(artifact: $0.artifact) }
            .sorted { ($0.document.title ?? "") < ($1.document.title ?? "") }
    }
}
