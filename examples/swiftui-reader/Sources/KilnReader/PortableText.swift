import Foundation
import KilnModels
import SwiftUI

/// Portable Text to an `AttributedString` that `Text` renders natively: no
/// web view, no HTML parser.
///
/// - `strong`, `em`, `code` and `strike` become inline presentation intents,
///   `underline` an underline style, a `link` mark def a `.link`.
/// - `h1`–`h6` get a heading font and a header presentation intent;
///   `blockquote` is set off with a bar and secondary colour.
/// - List items are prefixed with a bullet or their number, indented by
///   `level`; numbering restarts after any non-list block.
/// - A node whose `_type` isn't `block` is skipped, as the convention asks.
///
/// It reads the generated `PortableTextBlock`, which declares every key used
/// here, so a `rich_text` block's `body` and a `custom_fields_portable` value
/// render straight from the decoded document.
public enum PortableTextRenderer {
    public static func attributedString(_ nodes: [PortableTextBlock]) -> AttributedString {
        var output = AttributedString()
        var counters: [Int: Int] = [:]
        var previousWasListItem = false
        var identity = 0

        for node in nodes where node.type == "block" {
            let level = max(node.level ?? 1, 1)
            var prefix = ""

            if let list = node.listItem {
                counters = counters.filter { $0.key <= level }
                if list == "number" {
                    counters[level, default: 0] += 1
                    prefix = "\(counters[level]!). "
                } else {
                    counters[level] = nil
                    prefix = "• "
                }
                prefix = String(repeating: "    ", count: level - 1) + prefix
            } else {
                counters = [:]
            }

            if !output.characters.isEmpty {
                // List items sit on consecutive lines; anything else gets a
                // blank line before it.
                output += AttributedString(previousWasListItem && node.listItem != nil ? "\n" : "\n\n")
            }
            previousWasListItem = node.listItem != nil

            var paragraph = AttributedString(prefix)
            for span in node.children ?? [] where (span.type ?? "span") == "span" {
                paragraph += styled(span, markDefs: node.markDefs ?? [])
            }

            identity += 1
            switch node.style {
            case let style? where style.count == 2 && style.hasPrefix("h"):
                let header = Int(style.dropFirst()) ?? 1
                paragraph.font = headingFont(header)
                paragraph.presentationIntent = PresentationIntent(.header(level: header), identity: identity)
            case "blockquote":
                paragraph = AttributedString("▍ ") + paragraph
                paragraph.foregroundColor = .secondary
                paragraph.presentationIntent = PresentationIntent(.blockQuote, identity: identity)
            default:
                break
            }

            output += paragraph
        }

        return output
    }

    static func styled(_ span: PortableTextBlock.ChildrenItem, markDefs: [PortableTextBlock.MarkDefsItem]) -> AttributedString {
        var text = AttributedString(span.text ?? "")
        var intent: InlinePresentationIntent = []

        for mark in span.marks ?? [] {
            switch mark {
            case "strong": intent.insert(.stronglyEmphasized)
            case "em": intent.insert(.emphasized)
            case "code": intent.insert(.code)
            case "strike", "strike-through": intent.insert(.strikethrough)
            case "underline": text.underlineStyle = .single
            default:
                // A mark def: a link, unless its href was blanked as unsafe.
                if let def = markDefs.first(where: { $0.key == mark }), def.type == "link",
                   let href = def.href, !href.isEmpty, let url = URL(string: href) {
                    text.link = url
                }
            }
        }

        if !intent.isEmpty { text.inlinePresentationIntent = intent }
        return text
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.bold()
        default: return .headline
        }
    }
}
