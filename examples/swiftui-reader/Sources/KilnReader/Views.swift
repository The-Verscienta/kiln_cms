import KilnModels
import SwiftUI

/// The list: recipes from the sync mirror, with the `?fields=` featured card
/// on top. Pull to refresh runs one sync delta, not a request per row.
public struct RecipeListView: View {
    @Bindable var reader: Reader

    public init(reader: Reader) { self.reader = reader }

    public var body: some View {
        NavigationStack {
            List {
                if let card = reader.featured, let recipe = reader.recipes.first(where: { $0.id == card.id }) {
                    Section("Featured") {
                        NavigationLink(value: recipe) { FeaturedCard(card: card, client: reader.client) }
                    }
                }
                Section {
                    ForEach(reader.recipes) { recipe in
                        NavigationLink(value: recipe) { RecipeRow(recipe: recipe, client: reader.client) }
                    }
                } footer: {
                    if let status = reader.status { Text(status) }
                }
            }
            .overlay {
                if reader.recipes.isEmpty {
                    if reader.syncing { ProgressView("Syncing…") } else { ContentUnavailableView("No recipes yet", systemImage: "fork.knife") }
                }
            }
            .navigationTitle("Recipes")
            .navigationDestination(for: Recipe.self) { RecipeDetailView(reader: reader, recipe: $0) }
            .refreshable { await reader.refresh() }
            .toolbar {
                ToolbarItem { Button("Sync", systemImage: "arrow.clockwise") { Task { await reader.refresh() } } }
            }
            .task { await reader.refresh() }
        }
    }
}

struct RecipeRow: View {
    let recipe: Recipe
    let client: KilnClient

    var body: some View {
        let fields = recipe.document.customFields
        HStack(spacing: 12) {
            if let hero = fields.hero {
                FocalImage(media: hero, client: client).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.document.title ?? "Untitled").font(.headline)
                Text(summary(fields)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    func summary(_ fields: RecipeDocument.CustomFields) -> String {
        [fields.minutes.map { "\($0) min" }, fields.serves.map { "serves \($0)" }, fields.ingredients.map { "\($0.count) ingredients" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct FeaturedCard: View {
    let card: RecipeCard
    let client: KilnClient

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let hero = card.customFields?.hero {
                // A wide banner from a 3:2 original: the focal point keeps
                // the plate in frame.
                FocalImage(media: hero, client: client).frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Text(card.title ?? "").font(.headline)
                Spacer()
                if let minutes = card.customFields?.minutes { Text("\(minutes) min").foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The detail screen: the `:group` rows as a native list, the rich `method`
/// field as Portable Text → `AttributedString` (plain rendition as the
/// fallback), and the hero cropped around its focal point.
public struct RecipeDetailView: View {
    let reader: Reader
    @State var recipe: Recipe

    public init(reader: Reader, recipe: Recipe) {
        self.reader = reader
        _recipe = State(initialValue: recipe)
    }

    public var body: some View {
        let document = recipe.document
        let fields = document.customFields

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let hero = fields.hero {
                    FocalImage(media: hero, client: reader.client)
                        .frame(height: 240)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel(hero.alt ?? "")
                }

                HStack(spacing: 16) {
                    if let minutes = fields.minutes { Label("\(minutes) min", systemImage: "clock") }
                    if let serves = fields.serves { Label("Serves \(serves)", systemImage: "person.2") }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                    BlockView(block: block, nodes: index < recipe.bodies.count ? recipe.bodies[index] : nil)
                }

                if let rows = fields.ingredients, !rows.isEmpty {
                    Text("Ingredients").font(.title2.bold())
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text(quantity(row)).monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                Text(row.item ?? "")
                            }
                        }
                    }
                }

                if let method = methodText {
                    Text("Method").font(.title2.bold())
                    Text(method)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle(document.title ?? "")
        .refreshable { recipe = await reader.revalidate(recipe) }
        .task { recipe = await reader.revalidate(recipe) }
    }

    /// Portable Text when the field delivers it, the plain rendition (with
    /// its paragraph breaks) when not. Never the HTML in `custom_fields`.
    var methodText: AttributedString? {
        if let nodes = recipe.portable["method"] ?? nil, !nodes.isEmpty {
            return PortableTextRenderer.attributedString(nodes)
        }
        return recipe.document.customFieldsPlain?.method.map { AttributedString($0) }
    }

    func quantity(_ row: RecipeDocument.CustomFields.IngredientsItem) -> String {
        guard let amount = row.amount else { return "" }
        let number = amount.rounded() == amount ? String(Int(amount)) : String(amount)
        return [number, row.unit].compactMap { $0 }.joined(separator: " ")
    }
}

/// Blocks with a native rendering; the rest (including `.unknown`, a block
/// type newer than this build) are skipped rather than failing the screen.
struct BlockView: View {
    let block: Block
    /// The block's `body` as renderer nodes, when it has one.
    let nodes: [PortableTextNode]?

    var body: some View {
        switch block {
        case .richText:
            // The same renderer as the `method` field: a rich_text block's
            // body and a delivered Portable Text field are one shape.
            Text(PortableTextRenderer.attributedString(nodes ?? []))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let heading):
            Text(heading.text).font(.title3.bold())
        default:
            EmptyView()
        }
    }
}

/// An image that fills its frame, cropped around the snapshot's focal
/// point. The variant is chosen for the frame's pixel width, and the space
/// is reserved from the snapshot's dimensions before anything downloads.
public struct FocalImage: View {
    let media: MediaSnapshot
    let client: KilnClient
    @Environment(\.displayScale) private var scale

    public init(media: MediaSnapshot, client: KilnClient) {
        self.media = media
        self.client = client
    }

    public var body: some View {
        GeometryReader { geometry in
            let frame = geometry.size
            let ratio = MediaLayout.aspectRatio(of: media) ?? 1.5
            let layout = MediaLayout.fill(frame: frame, aspectRatio: ratio, focal: media.focalPoint)
            let url = client.resolve(MediaLayout.source(for: media, pixelWidth: layout.size.width * scale))

            AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                if let image = phase.image {
                    image.resizable()
                        .frame(width: layout.size.width, height: layout.size.height)
                        .offset(layout.offset)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .clipped()
        }
    }
}
