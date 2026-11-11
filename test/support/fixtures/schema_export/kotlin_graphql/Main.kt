// Decode harness for `KilnCMS.SchemaExport.KotlinCompileTest`: compiled with the
// generated `full.graphql.kt` (package `kiln`), it decodes a `PostCustomFields`
// result as the server returns it (every custom-field value kind), round-trips
// it and exits non-zero on the first mismatch.
package kiln

import kotlin.system.exitProcess

fun check(ok: Boolean, what: String) {
    if (!ok) {
        println("FAIL $what")
        exitProcess(1)
    }
}

fun main() {
    val json = """
    {"rating": 4.5, "readTime": 7, "subtitle": null, "customPublishedAt": "2026-01-01T00:00:00Z",
     "fields": [
      {"__typename":"GeolocationValue","name":"where","lat":1.5,"lng":2.5,"label":null,"zoom":12},
      {"__typename":"ListValue","name":"dosages","items":[{"__typename":"StringValue","name":"x","asString":"a"},{"__typename":"GroupValue","name":"g","fields":[{"__typename":"IntValue","name":"n","asInt":3}]}]},
      {"__typename":"MediaValue","name":"gallery","id":"u1","url":"http://x","alt":null,"width":10,"height":null,"mimeType":"image/png","focal":{"x":0.5,"y":0.5},"variants":[{"label":"t","width":1,"height":1,"format":"webp","url":"u","bytes":99,"cropped":false}]},
      {"__typename":"JsonValue","name":"j","asJson":null},
      {"__typename":"ReferenceValue","name":"r","ids":["a","b"]},
      {"__typename":"FutureValue","name":"zz"}
     ]}
    """
    // A plain `Json`: the serializer must not depend on `ignoreUnknownKeys`.
    val strict = kotlinx.serialization.json.Json
    val v = strict.decodeFromString(PostCustomFields.serializer(), json)
    check(v.rating == 4.5 && v.readTime == 7L && v.subtitle == null, "scalars")
    check(v.fields.size == 6, "field count")
    val geo = v.fields[0] as? KilnCustomFieldValue.GeolocationValue
    check(geo != null && geo.name == "where" && geo.lat == 1.5 && geo.zoom == 12.0 && geo.label == null, "geolocation")
    val list = v.fields[1] as? KilnCustomFieldValue.ListValue
    val group = list?.items?.get(1) as? KilnCustomFieldValue.GroupValue
    val n = group?.fields?.get(0) as? KilnCustomFieldValue.IntValue
    check(n != null && n.value == 3L, "list > group > int")
    val media = v.fields[2] as? KilnCustomFieldValue.MediaValue
    check(media != null && media.id == "u1" && media.variants[0].bytes == 99L && media.focal?.x == 0.5, "media")
    val unknown = v.fields[5] as? KilnCustomFieldValue.Unknown
    check(unknown != null && unknown.typename == "FutureValue" && unknown.name == "zz", "unknown")
    val back = strict.decodeFromString(PostCustomFields.serializer(), strict.encodeToString(PostCustomFields.serializer(), v))
    check(back == v, "round trip")
    check(PostCustomFields.FRAGMENT.startsWith("fragment PostCustomFields on Post {"), "fragment")
    println("kotlin ok")
}
