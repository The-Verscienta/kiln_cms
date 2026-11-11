// Decode harness for `KilnCMS.SchemaExport.SwiftCompileTest`: compiled with the
// generated `full.graphql.swift`, it decodes a `PostCustomFields` result as the
// server returns it (every custom-field value kind), round-trips it and exits
// non-zero on the first mismatch.
import Foundation
let json = """
{"rating": 4.5, "readTime": 7, "subtitle": null, "customPublishedAt": "2026-01-01T00:00:00Z",
 "fields": [
  {"__typename":"GeolocationValue","name":"where","lat":1.5,"lng":2.5,"label":null,"zoom":12},
  {"__typename":"ListValue","name":"dosages","items":[{"__typename":"StringValue","name":"x","asString":"a"},{"__typename":"GroupValue","name":"g","fields":[{"__typename":"IntValue","name":"n","asInt":3}]}]},
  {"__typename":"MediaValue","name":"gallery","id":"u1","url":"http://x","alt":null,"width":10,"height":null,"mimeType":"image/png","focal":{"x":0.5,"y":0.5},"variants":[{"label":"t","width":1,"height":1,"format":"webp","url":"u","bytes":99,"cropped":false}]},
  {"__typename":"JsonValue","name":"j","asJson":null},
  {"__typename":"ReferenceValue","name":"r","ids":["a","b"]},
  {"__typename":"FutureValue","name":"zz"}
 ]}
""".data(using: .utf8)!
let v = try JSONDecoder().decode(PostCustomFields.self, from: json)
precondition(v.rating == 4.5 && v.readTime == 7 && v.subtitle == nil)
precondition(v.fields.count == 6)
if case .geolocation(let n, let g) = v.fields[0] { precondition(n == "where" && g.lat == 1.5 && g.zoom == 12 && g.label == nil) } else { fatalError("geo") }
if case .list(_, let items) = v.fields[1], case .group(_, let f) = items[1], case .int(_, let n) = f[0] { precondition(n == 3) } else { fatalError("list") }
if case .media(_, let m) = v.fields[2] { precondition(m.id == "u1" && m.variants[0].bytes == 99 && m.focal?.x == 0.5) } else { fatalError("media") }
if case .unknown(let t, _) = v.fields[5] { precondition(t == "FutureValue") } else { fatalError("unknown") }
let data = try JSONEncoder().encode(v)
let back = try JSONDecoder().decode(PostCustomFields.self, from: data)
precondition(back == v)
precondition(PostCustomFields.fragment.hasPrefix("fragment PostCustomFields on Post {"))
print("swift ok")
