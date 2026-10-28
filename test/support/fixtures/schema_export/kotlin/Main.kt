// Decode harness for `KilnCMS.SchemaExport.KotlinCompileTest`: compiled together
// with a generated `Kiln.kt` (package `kiln`), it decodes the fired artifact
// named on the command line, prints what it read one `key=value` per line, and
// checks the value survives an encode/decode round trip.
package kiln

import java.io.File
import kotlin.system.exitProcess
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

fun describe(block: Block): String = when (block) {
    is ColumnsBlock -> "columns[" + (block.columns ?: emptyList()).flatMap { it.blocks }.joinToString(",") { describe(it) } + "]"
    is Block.Unknown -> "unknown:${block.type}"
    // Through the serializer, which stamps the tag back on.
    else -> KilnJson.encodeToJsonElement(Block.serializer(), block).jsonObject["_type"]!!.jsonPrimitive.content
}

fun main(args: Array<String>) {
    try {
        val document = KilnJson.decodeFromString(Document.serializer(), File(args[0]).readText())

        val post = document as? PostDocument
        if (post == null) {
            println("error=not a post: $document")
            exitProcess(1)
        }

        val fields = post.customFields
        println("title=${post.title ?: "nil"}")
        println("blocks=${post.blocks.joinToString(",") { describe(it) }}")
        println("subtitle=${fields.subtitle ?: "nil"}")
        println("summary_plain=${post.customFieldsPlain?.summary ?: "nil"}")
        println("read_time=${fields.readTime ?: "nil"}")
        println("properties=${(fields.properties ?: emptyList()).joinToString(",")}")
        println("dosages=${(fields.dosages ?: emptyList()).joinToString(",") { "${it.amount ?: 0.0}${it.unit ?: ""}" }}")
        println("seo_title=${fields.seo?.title ?: "nil"}")
        println("hero=${if (fields.hero == null) "nil" else "set"}")

        val again = KilnJson.decodeFromString(Document.serializer(), KilnJson.encodeToString(Document.serializer(), document))
        println("round_trip=${again == document}")
    } catch (e: Exception) {
        println("error=$e")
        exitProcess(1)
    }
}
