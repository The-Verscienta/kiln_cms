// Decode harness for `KilnCMS.SchemaExport.SwiftCompileTest`: compiled together
// with a generated `Kiln.swift`, it decodes the fired artifact named on the
// command line, prints what it read one `key=value` per line, and checks the
// value survives an encode/decode round trip.
import Foundation

func describe(_ block: Block) -> String {
    switch block {
    case .columns(let columns):
        let inner = (columns.columns ?? []).flatMap(\.blocks).map(describe).joined(separator: ",")
        return "columns[\(inner)]"
    case .unknown(let type):
        return "unknown:\(type)"
    default:
        return block.type
    }
}

let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))

do {
    let document = try JSONDecoder().decode(Document.self, from: data)

    guard case .post(let post) = document else {
        print("error=not a post: \(document.type)")
        exit(1)
    }

    let fields = post.customFields
    print("title=\(post.title ?? "nil")")
    print("blocks=\(post.blocks.map(describe).joined(separator: ","))")
    print("subtitle=\(fields.subtitle ?? "nil")")
    print("summary_plain=\(post.customFieldsPlain?.summary ?? "nil")")
    print("read_time=\(fields.readTime.map(String.init) ?? "nil")")
    print("properties=\((fields.properties ?? []).joined(separator: ","))")
    print("dosages=\((fields.dosages ?? []).map { "\($0.amount ?? 0)\($0.unit ?? "")" }.joined(separator: ","))")
    print("seo_title=\(fields.seo?.title ?? "nil")")
    print("hero=\(fields.hero == nil ? "nil" : "set")")

    let again = try JSONDecoder().decode(Document.self, from: try JSONEncoder().encode(document))
    print("round_trip=\(again == document)")
} catch {
    print("error=\(error)")
    exit(1)
}
