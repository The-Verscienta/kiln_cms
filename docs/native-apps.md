# Kiln in a native app

How to keep an iOS or Android app's content current from Kiln without
wasting the user's battery or data. Nothing here is mobile-only; it is the
headless API used from a client that sleeps, loses its network and pays for
every byte. The endpoint reference is [api.md](api.md). The general consumer
guide is [headless-consumer-guide.md](headless-consumer-guide.md).

[`examples/swiftui-reader`](https://github.com/The-Verscienta/kiln_cms/tree/main/examples/swiftui-reader) is a small
SwiftUI app that does everything on this page: generated models, a sync
mirror, `ETag` revalidation, `?fields=`, Portable Text rendered natively and
focal-point cropping.

Three reads cover almost every app:

| Need | Endpoint | Section |
|---|---|---|
| Keep a local copy of a type (or all public content) | `GET /api/sync` | [Mirroring with sync](#mirroring-with-sync) |
| Refresh the one document on screen | `GET /api/content/:type/:slug` + `If-None-Match` | [Refreshing one document](#refreshing-one-document) |
| A list row or widget, not the whole document | `GET /api/content/:type/:slug?fields=…` | [Smaller payloads](#smaller-payloads-fields) |

Read anonymously. A delivery app needs no credential for published, public
content, and a credential makes every response `private, no-store`
([api.md → Caching and CDNs](api.md#caching-and-cdns)). Never ship an editor's
API key inside an app binary. Anyone who unpacks the app has it, and it reads
drafts.

## Mirroring with sync

`GET /api/sync` sends the public corpus once, then only what changed since a
cursor, deletions included ([api.md → Sync](api.md#sync-delta-api)). It is the
right base for an offline-first app: the local store is a mirror keyed by
document `id`, and every launch or background wake applies one delta.

```text
first run:   GET /api/sync?initial=true&type=post&limit=100
             → follow "cursor" while "has_more" is true
             → store the last cursor
later:       GET /api/sync?cursor=<stored>
             → follow "cursor" while "has_more" is true
             → store the last cursor
```

Apply items in order, keyed by `id`. An `upsert` replaces your copy with
`artifact`, the same body `GET /api/content/:type/:slug` serves. A `delete`
removes it. A `delete` for an id you don't hold is normal; ignore it. The same
item can arrive twice, and applying it twice is harmless.

### Persisting the cursor

- **Store the cursor in the same transaction as the items it covers.** Write the
  page's upserts and deletes and the page's `cursor` together (one Core Data /
  SwiftData save, one Room `@Transaction`). If the app is killed between the
  two, the next run either repeats the page, which is harmless, or has both.
  It never has a cursor that has moved past items it never stored.
- **Store it per page, not per run.** A first sync of a large site is many
  pages. Saving after each one means a sync cut short by the OS resumes where it
  stopped, not from `initial=true`.
- **Treat it as opaque.** It is a signed token. Don't parse it, and don't build
  one. It carries its own scope (site, `type`, `surface`), so `type` and
  `surface` on a cursor request are ignored. One cursor per scope: an app that
  mirrors `post` and `recipe` separately keeps two.
- **It does not expire on its own.** A cursor from months ago still resumes.

### When to restart with `initial=true`

Only when the server refuses the cursor: **`400` with code `invalid_cursor`**.
That means it was signed with a `SECRET_KEY_BASE` the server has since rotated,
belongs to another site, or was altered. Drop the stored cursor and run
`initial=true`. Keep your local data while the snapshot downloads, then delete
the ids the snapshot did not send. A refused cursor says nothing about which of
your documents are still live.

Do **not** restart on any other error:

| Response | Meaning | What to do |
|---|---|---|
| `503 artifact_compiling` + `Retry-After` | A document on this page has no fired artifact yet. One request queues firing for all of them. | Retry the **same** request, same cursor, after `Retry-After`. |
| `503 temporarily_unavailable` + `Retry-After` | The database is unreachable. | Retry the same request later. |
| `429` + `retry-after` | Rate limit (below). | Wait the given seconds. |
| `404` | Unknown `type` (the type was removed or renamed). | Stop syncing that scope. |
| Network error, timeout | — | Retry the same request with backoff. |

Restarting on a `503` throws away a good cursor and turns one slow page into a
full re-download.

A periodic full resync (say weekly, on Wi-Fi and power) is still worth having.
A few changes write no version to the document itself, such as editing a
fragment it embeds or its type's custom-field definitions, so sync does not
report them ([api.md → Sync](api.md#sync-delta-api), "Not seen").

### Backoff

`Retry-After` is in seconds; honour it when present. Otherwise use exponential
backoff with jitter: for example 2 s, 4 s, 8 s … capped at a few minutes, each
multiplied by a random factor between 0.5 and 1.5, so a fleet of phones waking
together does not retry in lockstep. Give up for this wake after a handful of
attempts and try again on the next one. The stored cursor has not moved, so
nothing is lost.

Rate limits are **per client IP**. `/api/sync` and `/api/content` share the
`api` bucket (120 requests a minute by default,
[api.md → Rate limits](api.md#rate-limits)). Behind carrier-grade NAT many of
your users can share one address, so keep request counts low. Use `limit=500`
for a first sync rather than many small pages, and don't poll faster than the
content changes. An app with a large audience on one carrier is the case for
putting a CDN, or your own backend, in front (below).

The official clients already do the page loop and retry `503`s:
`kiln.sync({ cursor })` in `@kiln-cms/client` (3 retries, 2 s apart by default)
and `KilnClient.sync(cursor: …)` in `kiln_client`. Neither restarts on
`invalid_cursor`; that decision is yours.

### Background refresh on iOS and Android

Neither platform runs your code on a schedule you choose:

- **iOS.** `BGAppRefreshTask` (BackgroundTasks) runs when the system decides,
  based on how often the user opens the app, battery and network. It is
  typically hours apart and may not run at all for an app the user rarely
  opens. Each run gets a short budget, about 30 seconds. Fetch one or two
  sync pages, save, and finish the task; the stored cursor carries the rest to
  the next run. Background `URLSession` transfers survive suspension but are
  meant for large downloads, not chatty JSON polling.
- **Android.** `WorkManager` periodic work has a 15-minute minimum interval,
  and Doze and App Standby buckets defer it further. Constrain the work to
  `NetworkType.CONNECTED` (or `UNMETERED` for the first full sync).

So background refresh is best-effort freshness, not delivery. Always sync on
foreground too: on launch and on returning to the app, run one delta before
showing "latest" lists. A delta for a quiet site is one small request. For
"show it now" (breaking news, a price change), use push (below).

## Refreshing one document

The single-document read, `GET /api/content/:type/:slug` (`surface=json` by
default), carries a weak `ETag` (`W/"…"`), `Last-Modified` and
`Cache-Control: public, max-age=300`. Send the `ETag` back as `If-None-Match`
and an unchanged document is a bodyless **`304 Not Modified`**. That makes a
pull-to-refresh on a detail screen cost a few hundred bytes.

```http
GET /api/content/post/hello
If-None-Match: W/"6f1c…-en-json-1792656000"

HTTP/1.1 304 Not Modified
```

- Send the tag back as received. The comparison is weak: the `W/` prefix is
  ignored, a comma-separated list matches if any tag in it does, and `*`
  matches any current version. The tag is weak so that Kiln can gzip the
  response: send `Accept-Encoding: gzip` (`URLSession` and OkHttp do by
  default) and the JSON arrives compressed. The tag changes when the
  document is republished, and it also names the served locale, the A/B
  variant (`?variant_key=`) and the `?expand=` targets, so a tag from one of
  those representations never `304`s another. A `?fields=`
  response is tagged by its body instead (below).
- `URLCache` (iOS) and OkHttp's `Cache` (Android) store the `ETag` and
  revalidate for you once the `max-age` has passed. Enable the cache with a
  real disk size and you get conditional requests without writing them.
- A passphrase-locked document read with an unlock grant is `private, no-store`
  and has no `ETag`. It is never `304`ed.

For a list screen, don't refresh each row with its own request. Run a sync
delta, which reports every changed or removed document in one request.

## Smaller payloads: `?fields=`

The `json` artifact is the whole document: every block and every custom field.
A list row needs a title and a thumbnail. `?fields=` keeps only what you name:

```bash
curl -s 'https://cms.example.com/api/content/recipe/pancakes?fields=title,slug,custom_fields.hero_image'
```

```json
{"id": "…", "type": "recipe", "title": "Pancakes", "slug": "pancakes",
 "custom_fields": {"hero_image": {"id": "…", "url": "…", "alt": "…"}}}
```

- Comma-separated **top-level keys** (`title`, `slug`, `locale`, `blocks`,
  `custom_fields`, `custom_fields_plain`, `custom_fields_portable`, and any
  other key the artifact carries) plus
  **`custom_fields.<name>`** for one custom field. `custom_fields` on its own
  keeps all of them.
- `id` and `type` are **always** kept. So is `expanded` when you also pass
  `?expand=`.
- Unknown names are **ignored**, not refused, so an app built against an older
  schema keeps working when a field is removed. A `custom_fields.<name>` that
  matches nothing leaves `"custom_fields": {}`.
- At most 50 names. `fields` needs `surface=json` (the default); with another
  surface it is a `400 invalid_fields`. It also works with `?as_of=`.
- **The `ETag` is a digest of the filtered body**, so it moves only when a
  value you kept does. After an editor republishes a recipe with a new
  method but the same title and hero image, revalidating the list row's
  fieldset is still a `304`. That is where `fields` saves the most on a
  phone. Revalidate a fieldset response with the tag that fieldset returned.
- **Order and repeats don't matter.** `?fields=slug,title` and
  `?fields=title,slug,title` return the same body and the same `ETag`. The
  response's **`x-kiln-fields`** header is the canonical spelling: sorted,
  de-duplicated, without `id`/`type`. A CDN keys on the full URL, so send
  the canonical spelling everywhere in your app and every install shares one
  cache entry.

`fields` is on the single-document artifact read only. `/api/sync` always sends
the whole artifact. For filtered **lists** with sparse fields, JSON:API has
`fields[<type>]=` ([json-api.md](json-api.md)), and GraphQL selects fields by
construction ([headless-graphql-api.md](headless-graphql-api.md)).

A fieldset response is deliberately **not** valid against the full document
schema from `GET /api/schema`, which lists `blocks`, `custom_fields`, `slug`
and the rest as required. Decode a fieldset response into a separate, smaller
type, or into a type whose properties beyond `id` and `type` are optional.

## Rich text without a web view

Prose in **blocks** is already structured: a `rich_text` block's `body` is
Portable Text, an array of blocks whose spans carry their formatting as data.
A rich `:text` **custom field** stores HTML instead (its `format` is `:rich`
by default; [extending-content.md](extending-content.md)), and
`custom_fields` delivers that HTML as it is.

So that an app does not need a browser engine to show it, an admin can tick
two per-field options in the fields admin. Both are off by default, and each
adds a sibling map beside `custom_fields`, which never changes:

| Option | Key | Value |
|---|---|---|
| Also deliver as plain text (`deliver_plain`) | `custom_fields_plain` | the text with tags removed and whitespace collapsed (paragraphs run together), for a list row or a search index |
| … and Keep paragraph breaks (`plain_breaks`) | `custom_fields_plain` | the same, but with `\n\n` between paragraphs and `\n` per line break or list item, for a text view that shows the prose as written; the schema export marks the field `x-kiln-plain-breaks` |
| Also deliver as Portable Text (`deliver_portable`, rich fields only) | `custom_fields_portable` | the same Portable Text tree a `rich_text` block's `body` holds: paragraphs, `h1`–`h6`, quotes, nested lists (`listItem` + `level`), `strong`/`em`/`code`/`strike`/`underline` marks, links in `markDefs` |

```json
"custom_fields": {"actions": "<p>Clears <em>heat</em>.</p>"},
"custom_fields_portable": {
  "actions": [
    {"_type": "block", "_key": "b0", "style": "normal", "markDefs": [],
     "children": [{"_type": "span", "marks": [], "text": "Clears "},
                  {"_type": "span", "marks": ["em"], "text": "heat"},
                  {"_type": "span", "marks": [], "text": "."}]}
  ]
}
```

- Every flagged field has a key. It is `null` when the record holds no value
  for it, and `[]` when the value is blank. A value stored as JSON data is
  `null`: it is not prose. A value with no markup at all becomes one
  paragraph per blank-line-separated run, with single newlines kept as `\n`
  inside the span.
- It is computed when the document fires, so the artifact read and
  `/api/sync` carry it at no extra cost. JSON:API
  (`fields[<type>]=…,custom_fields_portable`) and GraphQL
  (`customFieldsPortable`) serve it only when asked for. Ticking or clearing
  the option re-fires the type's published documents.
- Render it with the same code that renders a `rich_text` block's `body`. In
  `GET /api/schema` each value is the type `body` has, an array of
  `#/$defs/portable_text_block`, so generated models share one type. That
  definition is an open node that declares only `_type` and `_key`, so the
  Swift and Kotlin models drop `children`, `style` and `markDefs` on decode.
  Decode the Portable Text keys with a small node type of your own
  ([the SwiftUI example](https://github.com/The-Verscienta/kiln_cms/blob/main/examples/swiftui-reader/Sources/KilnReader/PortableText.swift)
  has one, with an `AttributedString` renderer).
- A link with an unsafe scheme keeps its text, but its `href` is `""`. An
  `<img>` inside the prose is dropped, as in a block's body (images are their
  own block in Kiln). The HTML in `custom_fields` is always the full value.
- Values inside a `:group` field's rows are not converted: the rows arrive
  whole in `custom_fields.<group>`.

## Push: webhooks, through your backend

Kiln has no device push. It does not hold APNs or FCM credentials or device
tokens. What it has is **signed outbound webhooks**
([webhooks.md](webhooks.md)). If your app has a backend, that backend is the
push path:

1. Register an endpoint on your backend at `/editor/webhooks`, subscribed to
   `<type>.published`, `<type>.updated`, `<type>.unpublished` and, if you
   mirror, `<type>.archived`/`<type>.deleted`.
2. Verify `x-kilncms-webhook-signature` (HMAC-SHA256 of `"<t>.<raw body>"`)
   and reject a `t` more than five minutes off. Use `delivery_id` to dedupe
   retries ([webhooks.md → Verifying the signature](webhooks.md#verifying-the-signature)).
3. Send an APNs/FCM message. Prefer a **silent / data message** that says
   "content changed" (iOS `content-available: 1`, an FCM data message). The app
   wakes and runs a sync delta. A visible notification is for things the user
   asked to be told about.

Don't put the document in the push payload. APNs and FCM payloads are capped
at about 4 KB, and the webhook body is the editor-facing shape, not the
delivery artifact. The device should fetch through sync or the artifact read,
which only ever serve what an anonymous reader may see. Mind `audience` and
`locked` in the webhook data too
(see *Gated content is delivered too* in [webhooks.md](webhooks.md)):
a members-only publish is still a `published` event.

The same backend can also front the content API: one sync loop on the server,
devices reading from your own store or CDN. That removes the per-IP rate-limit
concern above and lets you shape payloads for your app. It is worth it once the
audience is large.

An app without a backend relies on foreground sync plus best-effort background
refresh. That is fine for most content apps.

## Typed models from `GET /api/schema`

`GET /api/schema` is a JSON Schema (draft 2020-12) of exactly what the `json`
artifact serves: one document schema per content type and a `_type`-
discriminated block union ([api.md → Schema discovery](api.md#schema-discovery-typed-clients)).
It is per site, so it includes admin-defined types and custom fields, and it
changes when an admin edits them, without a redeploy.

- Generate models from it **at build time**, commit the output, and
  regenerate when the schema changes. Swift and Kotlin have built-in emitters
  ([Swift](#swift-models), [Kotlin](#kotlin-models)); TypeScript has
  `mix kiln.export.schema --format ts` and the `kiln-types` generator bundled
  with `@kiln-cms/client`.
- Use `?type=post,recipe` to export only the types the app reads. An unknown
  name is a `400`.
- Decode **leniently**. `custom_fields` is an open object and nothing in it is
  required: a field added after a document was last saved has no value, so
  every custom field is optional. Decode an unknown block `_type` to a
  placeholder case instead of failing the whole document, because a Kiln
  upgrade or a plugin can add a block kind your shipped binary has never seen.
- The fieldset caveat above applies: generated types describe the full
  document.

The schema is cacheable (`public, max-age=300`). An app can fetch it at runtime
to detect drift, but it can't change its compiled types. Use it in CI
instead: fail the build when the live schema no longer matches the committed
one.

### Swift models

`mix kiln.export.schema --format swift` writes one self-contained Swift file
from the same document `GET /api/schema` serves:

```bash
mix kiln.export.schema --format swift --org-id <site uuid> --out Sources/Kiln/Kiln.swift
```

Add `--type post,recipe` to emit only the types the app reads. The file needs
only the Swift standard library, so it drops into an app target or a Swift
package. What it contains:

- A `public struct … : Codable, Hashable, Sendable` per content type
  (`PostDocument`), block (`HeadingBlock`) and shared definition, with a public
  memberwise `init` for previews and tests. Inline objects nest inside the
  struct that holds them, named after their key: `PostDocument.CustomFields`,
  and a repeating `:group` row as `CustomFields.DosagesItem`. The media
  snapshot is one shared `MediaSnapshot`, used by a `:media` field, a
  gallery, and the `image` and `gallery` blocks alike.
- Swift names in `lowerCamelCase`, with `CodingKeys` keeping the JSON key
  exact (`readTime = "read_time"`, a block's `type = "_type"`). Keywords are
  back-ticked; a key Swift can't spell is sanitized, and its JSON name is kept.
- An optional for every key that is nullable **or** not required, so every
  custom field is optional, as it is on the wire.
- `public indirect enum Block`, switching on `_type`, and `Document`,
  switching on `type`. Each has an `.unknown(type: String)` case: a block kind
  added by an upgrade or a plugin decodes to that case and the rest of the
  document still decodes.
- A string `enum` in the schema becomes a `String`-backed enum with an
  `unknown(String)` case, so a new option never breaks decoding.
  `:select` custom fields are plain `String`s (or `[String]` for a multiple
  select), because the schema doesn't publish their options.
- `[String: JSONValue]` for an open map (a single `:reference` snapshot,
  `inherited_fields`) and `JSONValue` for anything the schema leaves
  unconstrained. `JSONValue` is a small enum bundled in the file.

What Swift can't state is dropped, as in the TypeScript emitter. A `uuid` or
`date-time` is a `String`: pick a date strategy where you decode. Numeric
bounds and `const` pins are dropped. Unknown keys on an open object are
ignored rather than kept. That includes the Portable Text node
(`PortableTextBlock`), which keeps only `type` and `key`. See
[Rich text without a web view](#rich-text-without-a-web-view).

[`examples/swiftui-reader`](https://github.com/The-Verscienta/kiln_cms/tree/main/examples/swiftui-reader) checks in
a generated file and the script that regenerates it.

Decode a delivery with `JSONDecoder`:

```swift
let document = try JSONDecoder().decode(Document.self, from: data)
if case .post(let post) = document {
    for block in post.blocks {
        if case .heading(let heading) = block { print(heading.text) }
    }
}
```

**Regenerating.** The file describes one site at the moment of export, so
regenerate it when an admin adds or changes a content type or custom field,
and after a Kiln upgrade or plugin adds a block. An app built against an older
file keeps decoding: new keys are ignored, and new block types and enum values
land in `unknown`. So regenerating is about gaining the new fields, not about
staying compatible. To catch drift in CI, regenerate and run
`git diff --exit-code` on the file.

### Kotlin models

`mix kiln.export.schema --format kotlin` writes one Kotlin file of
[kotlinx.serialization](https://github.com/Kotlin/kotlinx.serialization)
models from the same document:

```bash
mix kiln.export.schema --format kotlin --package com.example.kiln \
  --org-id <site uuid> --out app/src/main/java/com/example/kiln/Kiln.kt
```

`--package` sets the file's `package` and defaults to `kiln`. `--type
post,recipe` works as it does for Swift. The file needs the serialization
compiler plugin and the JSON runtime, nothing else. In `build.gradle.kts`:

```kotlin
plugins {
    kotlin("plugin.serialization") version "<your Kotlin version>"
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.12.0")
}
```

What it contains:

- A `@Serializable public data class` per content type (`PostDocument`),
  block (`HeadingBlock`) and shared definition. Inline objects nest inside the
  class that holds them, named as in Swift: `PostDocument.CustomFields`, and a
  repeating `:group` row as `CustomFields.DosagesItem`. The media snapshot is
  the one shared `MediaSnapshot`. An object with no keys is a `data object`.
- Kotlin names in `lowerCamelCase`, with `@SerialName` keeping the JSON key
  exact (`@SerialName("read_time") val readTime`, a block's
  `@SerialName("_type") val type`). Hard keywords are back-ticked.
- A nullable property with a `= null` default for every key that is nullable
  **or** not required, so every custom field is optional.
- `sealed interface Block`, which every block class implements, read by the
  bundled `BlockSerializer`. It switches on `_type`, and a block type the app
  doesn't know decodes to `Block.Unknown(type, raw)` while the rest of the
  document still decodes. `raw` is the block's `JsonObject`, and encoding an
  `Unknown` writes it back unchanged. `Document` and `DocumentSerializer` do
  the same for content types, switching on `type`. The serializers name each
  class's serializer directly, so there is no reflection lookup and nothing
  for R8 to strip.
- A string `enum` in the schema becomes a `@JvmInline value class` over
  `String`, with a companion constant per listed value (`Style.Primary`),
  `entries` and `isKnown`. Any string decodes, so a new option never breaks
  decoding. As in Swift, `:select` custom fields are plain `String`s (or
  `List<String>`), because the schema doesn't publish their options.
- `Long` for integers (JSON integers are not 32-bit), `JsonObject` for an open
  map, and `JsonElement` for anything the schema leaves unconstrained.

Decode with the bundled `KilnJson`, which sets `ignoreUnknownKeys = true`.
A plain `Json` fails on the first key the generated file doesn't list, and a
delivery gains keys before you regenerate:

```kotlin
when (val document = KilnJson.decodeFromString(Document.serializer(), body)) {
    is PostDocument -> document.blocks.forEach { block ->
        if (block is HeadingBlock) println(block.text)
    }
    is Document.Unknown -> Log.w("kiln", "unknown type ${document.type}")
    else -> Unit
}
```

The same things are dropped as in Swift: a `date-time` or `uuid` is a
`String`, numeric bounds and `const` pins are gone, and unknown keys on an
open object are ignored rather than kept. The regenerating advice above
applies unchanged.
