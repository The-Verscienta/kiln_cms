import KilnModels
@testable import KilnReader
import XCTest

/// The generated models against JSON captured from a real local Kiln
/// (`bin/capture-fixtures`): a fired `json` artifact, a `?fields=` read and
/// two sync pages.
final class FixtureDecodingTests: XCTestCase {
    func testTheFiredArtifactDecodesAsARecipe() throws {
        let document = try JSONDecoder().decode(Document.self, from: fixture("recipe-artifact"))
        guard case .recipe(let recipe) = document else { return XCTFail("decoded as \(document.type)") }

        XCTAssertEqual(recipe.slug, "buttermilk-pancakes")
        XCTAssertEqual(recipe.customFields.serves, 4)
        XCTAssertEqual(recipe.customFields.minutes, 25)

        // The `:group` field's rows, in the editor's order.
        let rows = try XCTUnwrap(recipe.customFields.ingredients)
        XCTAssertEqual(rows.map(\.item), ["Plain flour", "Buttermilk", "Eggs", "Baking powder", "Melted butter"])
        XCTAssertEqual(rows.first?.amount, 200)
        XCTAssertEqual(rows.first?.unit, "g")

        // The media snapshot: dimensions, focal point and variants.
        let hero = try XCTUnwrap(recipe.customFields.hero)
        XCTAssertEqual(hero.width, 1600)
        XCTAssertEqual(hero.height, 1067)
        XCTAssertEqual(hero.focal?.x, 0.72)
        XCTAssertEqual(hero.focal?.y, 0.36)
        XCTAssertTrue(hero.variants?.contains { $0.label == "medium.webp" && $0.width == 1024 && !$0.cropped } ?? false)
        XCTAssertTrue(hero.variants?.contains { $0.cropped } ?? false)

        // The plain rendition keeps its paragraph breaks (`plain_breaks`).
        let plain = try XCTUnwrap(recipe.customFieldsPlain?.method)
        XCTAssertTrue(plain.hasPrefix("Batter\n\nWhisk the flour"))

        // The rich_text block.
        guard case .richText(let intro) = try XCTUnwrap(recipe.blocks.first) else { return XCTFail("first block") }
        XCTAssertEqual(intro.body.count, 1)
    }

    /// The generated `PortableTextBlock` declares the standard keys, so the
    /// decoded document carries the text the renderer reads: the delivered
    /// field and a rich_text block's body alike.
    func testPortableTextDecodesThroughTheGeneratedNode() throws {
        let generated = try JSONDecoder().decode(RecipeDocument.self, from: fixture("recipe-artifact"))

        let method = try XCTUnwrap(generated.customFieldsPortable?.method)
        XCTAssertEqual(method.first?.type, "block")
        XCTAssertEqual(method.first?.style, "h2")
        XCTAssertEqual(method.first?.children?.first?.text, "Batter")
        XCTAssertEqual(method[1].listItem, "number")
        XCTAssertEqual(method[1].level, 1)
        XCTAssertEqual(method.last?.markDefs?.first?.href, "https://kilncms.dev")

        guard case .richText(let intro) = try XCTUnwrap(generated.blocks.first) else { return XCTFail("first block") }
        XCTAssertEqual(intro.body.first?.children?.first?.text, "Thick, soft pancakes for a slow weekend morning.")
    }

    /// A `?fields=` response is not a full document: it decodes into its own
    /// type, and not into the generated one.
    func testAFieldsetDecodesIntoItsOwnType() throws {
        let data = try fixture("recipe-fields")
        let card = try JSONDecoder().decode(RecipeCard.self, from: data)

        XCTAssertEqual(card.type, "recipe")
        XCTAssertEqual(card.title, "Buttermilk pancakes")
        XCTAssertEqual(card.customFields?.minutes, 25)
        XCTAssertEqual(card.customFields?.hero?.focal?.x, 0.72)
        XCTAssertThrowsError(try JSONDecoder().decode(RecipeDocument.self, from: data))
    }

    func testASyncSnapshotPage() throws {
        let page = try JSONDecoder().decode(SyncPage.self, from: fixture("sync-initial-page"))

        XCTAssertTrue(page.hasMore)
        XCTAssertFalse(page.cursor.isEmpty)
        XCTAssertEqual(page.items.map(\.op), [.upsert, .upsert])

        for item in page.items {
            let recipe = try Recipe(artifact: XCTUnwrap(item.artifact))
            XCTAssertEqual(recipe.id, item.id)
            XCTAssertEqual(recipe.document.slug, item.slug)
        }
    }

    func testASyncDeltaCarriesADeletion() throws {
        let page = try JSONDecoder().decode(SyncPage.self, from: fixture("sync-delta-page"))
        let delete = try XCTUnwrap(page.items.first { $0.op == .delete })

        XCTAssertEqual(delete.type, "recipe")
        XCTAssertNil(delete.slug)
        XCTAssertNil(delete.artifact)
    }
}

func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}
