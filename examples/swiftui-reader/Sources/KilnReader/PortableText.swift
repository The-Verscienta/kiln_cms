import Foundation
import SwiftUI

/// One Portable Text node, with the keys a renderer reads.
///
/// The generated `PortableTextBlock` is the schema's open node: it declares
/// only `_type` and `_key`, because Portable Text is an extensible
/// convention, so it decodes without `children`, `style` or `markDefs`.
/// The renderer needs those, so it decodes the same JSON into this type.
public struct PortableTextNode: Decodable, Hashable, Sendable {
    public var type: String
    public var key: String?
    public var style: String?
    public var listItem: String?
    public var level: Int?
    public var children: [Span]
    public var markDefs: [MarkDef]

    public struct Span: Decodable, Hashable, Sendable {
        public var type: String
        public var text: String
        public var marks: [String]

        enum CodingKeys: String, CodingKey { case type = "_type", text, marks }

        public init(text: String, marks: [String] = []) {
            self.type = "span"
            self.text = text
            self.marks = marks
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? "span"
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            marks = try c.decodeIfPresent([String].self, forKey: .marks) ?? []
        }
    }

    public struct MarkDef: Decodable, Hashable, Sendable {
        public var key: String
        public var type: String
        public var href: String?

        enum CodingKeys: String, CodingKey { case key = "_key", type = "_type", href }

        public init(key: String, type: String = "link", href: String?) {
            self.key = key
            self.type = type
            self.href = href
        }
    }

    enum CodingKeys: String, CodingKey {
        case type = "_type", key = "_key", style, listItem, level, children, markDefs
    }

    public init(style: String? = "normal", listItem: String? = nil, level: Int? = nil, children: [Span], markDefs: [MarkDef] = []) {
        self.type = "block"
        self.style = style
        self.listItem = listItem
        self.level = level
        self.children = children
        self.markDefs = markDefs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        key = try c.decodeIfPresent(String.self, forKey: .key)
        style = try c.decodeIfPresent(String.self, forKey: .style)
        listItem = try c.decodeIfPresent(String.self, forKey: .listItem)
        level = try c.decodeIfPresent(Int.self, forKey: .level)
        // An unknown node type has neither; it is skipped when rendered.
        children = (try? c.decodeIfPresent([Span].self, forKey: .children)) ?? []
        markDefs = (try? c.decodeIfPresent([MarkDef].self, forKey: .markDefs)) ?? []
    }
}

/// The `custom_fields_portable` map of an artifact, read with the renderer's
/// node type. `nil` for a field means the record holds no value.
public struct PortableFields: Decodable, Sendable {
    public let fields: [String: [PortableTextNode]?]

    enum CodingKeys: String, CodingKey { case fields = "custom_fields_portable" }

    public init(from decoder: Decoder) throws {
        fields = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent([String: [PortableTextNode]?].self, forKey: .fields) ?? [:]
    }

    public subscript(name: String) -> [PortableTextNode]? { fields[name] ?? nil }
}

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
public enum PortableTextRenderer {
    public static func attributedString(_ nodes: [PortableTextNode]) -> AttributedString {
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
            for span in node.children where span.type == "span" {
                paragraph += styled(span, markDefs: node.markDefs)
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

    static func styled(_ span: PortableTextNode.Span, markDefs: [PortableTextNode.MarkDef]) -> AttributedString {
        var text = AttributedString(span.text)
        var intent: InlinePresentationIntent = []

        for mark in span.marks {
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
