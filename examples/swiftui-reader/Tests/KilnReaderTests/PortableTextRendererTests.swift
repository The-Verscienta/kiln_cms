import KilnModels
@testable import KilnReader
import SwiftUI
import XCTest

final class PortableTextRendererTests: XCTestCase {
    typealias Node = PortableTextBlock
    typealias Span = PortableTextBlock.ChildrenItem
    typealias MarkDef = PortableTextBlock.MarkDefsItem

    func testMarksBecomeInlineAttributes() {
        let text = render([
            block(children: [
                span("bold", ["strong"]), span(" "),
                span("it", ["em"]), span(" "),
                span("x()", ["code"]), span(" "),
                span("gone", ["strike"]), span(" "),
                span("under", ["underline"]), span(" "),
                span("both", ["strong", "em"]),
            ]),
        ])

        XCTAssertEqual(String(text.characters), "bold it x() gone under both")
        XCTAssertEqual(run(text, "bold")?.inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertEqual(run(text, "it")?.inlinePresentationIntent, .emphasized)
        XCTAssertEqual(run(text, "x()")?.inlinePresentationIntent, .code)
        XCTAssertEqual(run(text, "gone")?.inlinePresentationIntent, .strikethrough)
        XCTAssertEqual(run(text, "under")?.underlineStyle, .single)
        XCTAssertEqual(run(text, "both")?.inlinePresentationIntent, [.stronglyEmphasized, .emphasized])
        XCTAssertNil(run(text, " ")?.inlinePresentationIntent)
    }

    func testLinksComeFromMarkDefsAndABlankedHrefIsJustText() {
        let text = render([
            block(
                children: [span("safe", ["a"]), span(" "), span("unsafe", ["b"])],
                markDefs: [link("a", "https://kilncms.dev"), link("b", "")]
            ),
        ])

        XCTAssertEqual(run(text, "safe")?.link, URL(string: "https://kilncms.dev"))
        XCTAssertNil(run(text, "unsafe")?.link)
    }

    func testHeadingsQuotesAndParagraphSpacing() {
        let text = render([
            block(style: "h2", children: [span("Batter")]),
            block(children: [span("Mix.")]),
            block(style: "blockquote", children: [span("Lumps are fine.")]),
        ])

        XCTAssertEqual(String(text.characters), "Batter\n\nMix.\n\n▍ Lumps are fine.")
        XCTAssertEqual(run(text, "Batter")?.font, .title2.bold())
        XCTAssertEqual(run(text, "Batter")?.presentationIntent?.components.first?.kind, .header(level: 2))
        XCTAssertEqual(run(text, "▍ Lumps are fine.")?.foregroundColor, .secondary)
        XCTAssertNotNil(run(text, "Mix."))
        XCTAssertNil(run(text, "Mix.")?.font)
    }

    func testListsAreNumberedAndIndentedByLevel() {
        let text = render([
            block(listItem: "number", level: 1, children: [span("One")]),
            block(listItem: "number", level: 1, children: [span("Two")]),
            block(listItem: "bullet", level: 2, children: [span("Detail")]),
            block(listItem: "number", level: 1, children: [span("Three")]),
            block(children: [span("After.")]),
            block(listItem: "number", level: 1, children: [span("Again")]),
        ])

        XCTAssertEqual(String(text.characters), "1. One\n2. Two\n    • Detail\n3. Three\n\nAfter.\n\n1. Again")
    }

    func testUnknownNodesAreSkipped() {
        let image = block(type: "image", children: [span("alt")])

        XCTAssertEqual(String(render([image, block(children: [span("Kept")])]).characters), "Kept")
        XCTAssertEqual(String(render([]).characters), "")
    }

    /// The real `method` field from the captured artifact.
    func testTheCapturedMethodField() throws {
        let recipe = try Recipe(data: fixture("recipe-artifact"))
        let text = render(try XCTUnwrap(recipe.document.customFieldsPortable?.method))

        XCTAssertTrue(String(text.characters).hasPrefix("Batter\n\n1. Whisk the flour and baking powder.\n2. Beat in"))
        XCTAssertEqual(run(text, "flour")?.inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertEqual(run(text, "2 min")?.inlinePresentationIntent, .code)
        XCTAssertEqual(run(text, "the Kiln docs")?.link, URL(string: "https://kilncms.dev"))
    }

    // MARK: -

    func render(_ nodes: [Node]) -> AttributedString { PortableTextRenderer.attributedString(nodes) }

    /// A `block` node as the serializer writes one.
    func block(type: String = "block", style: String? = "normal", listItem: String? = nil, level: Int? = nil, children: [Span], markDefs: [MarkDef] = []) -> Node {
        Node(type: type, children: children, level: level, listItem: listItem, markDefs: markDefs, style: style)
    }

    func span(_ text: String, _ marks: [String] = []) -> Span { Span(type: "span", marks: marks, text: text) }

    func link(_ key: String, _ href: String) -> MarkDef { MarkDef(key: key, type: "link", href: href) }

    /// The attributes at the first occurrence of `string`, which must be
    /// styled as one run.
    func run(_ text: AttributedString, _ string: String) -> AttributedString.Runs.Run? {
        guard let range = text.range(of: string) else { return nil }
        let runs = text[range].runs
        XCTAssertEqual(runs.count, 1, "\(string) spans \(runs.count) runs")
        return runs.first
    }
}
