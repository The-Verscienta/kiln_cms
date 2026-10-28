@testable import KilnReader
import SwiftUI
import XCTest

final class PortableTextRendererTests: XCTestCase {
    typealias Node = PortableTextNode
    typealias Span = PortableTextNode.Span

    func testMarksBecomeInlineAttributes() {
        let text = render([
            Node(children: [
                Span(text: "bold", marks: ["strong"]), Span(text: " "),
                Span(text: "it", marks: ["em"]), Span(text: " "),
                Span(text: "x()", marks: ["code"]), Span(text: " "),
                Span(text: "gone", marks: ["strike"]), Span(text: " "),
                Span(text: "under", marks: ["underline"]), Span(text: " "),
                Span(text: "both", marks: ["strong", "em"]),
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
            Node(
                children: [Span(text: "safe", marks: ["a"]), Span(text: " "), Span(text: "unsafe", marks: ["b"])],
                markDefs: [.init(key: "a", href: "https://kilncms.dev"), .init(key: "b", href: "")]
            ),
        ])

        XCTAssertEqual(run(text, "safe")?.link, URL(string: "https://kilncms.dev"))
        XCTAssertNil(run(text, "unsafe")?.link)
    }

    func testHeadingsQuotesAndParagraphSpacing() {
        let text = render([
            Node(style: "h2", children: [Span(text: "Batter")]),
            Node(children: [Span(text: "Mix.")]),
            Node(style: "blockquote", children: [Span(text: "Lumps are fine.")]),
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
            Node(listItem: "number", level: 1, children: [Span(text: "One")]),
            Node(listItem: "number", level: 1, children: [Span(text: "Two")]),
            Node(listItem: "bullet", level: 2, children: [Span(text: "Detail")]),
            Node(listItem: "number", level: 1, children: [Span(text: "Three")]),
            Node(children: [Span(text: "After.")]),
            Node(listItem: "number", level: 1, children: [Span(text: "Again")]),
        ])

        XCTAssertEqual(String(text.characters), "1. One\n2. Two\n    • Detail\n3. Three\n\nAfter.\n\n1. Again")
    }

    func testUnknownNodesAreSkipped() {
        var image = Node(children: [Span(text: "alt")])
        image.type = "image"

        XCTAssertEqual(String(render([image, Node(children: [Span(text: "Kept")])]).characters), "Kept")
        XCTAssertEqual(String(render([]).characters), "")
    }

    /// The real `method` field from the captured artifact.
    func testTheCapturedMethodField() throws {
        let recipe = try Recipe(data: fixture("recipe-artifact"))
        let text = render(try XCTUnwrap(recipe.portable["method"] ?? nil))

        XCTAssertTrue(String(text.characters).hasPrefix("Batter\n\n1. Whisk the flour and baking powder.\n2. Beat in"))
        XCTAssertEqual(run(text, "flour")?.inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertEqual(run(text, "2 min")?.inlinePresentationIntent, .code)
        XCTAssertEqual(run(text, "the Kiln docs")?.link, URL(string: "https://kilncms.dev"))
    }

    // MARK: -

    func render(_ nodes: [Node]) -> AttributedString { PortableTextRenderer.attributedString(nodes) }

    /// The attributes at the first occurrence of `string`, which must be
    /// styled as one run.
    func run(_ text: AttributedString, _ string: String) -> AttributedString.Runs.Run? {
        guard let range = text.range(of: string) else { return nil }
        let runs = text[range].runs
        XCTAssertEqual(runs.count, 1, "\(string) spans \(runs.count) runs")
        return runs.first
    }
}
