# 0010. Embed metadata is resolved server-side against a curated provider list

- **Status** — accepted, shipped in
  [0.5.0](../changelog/v0.5.0.md) (Fixed).
- **References** — [#489](https://github.com/The-Verscienta/kiln_cms/issues/489).
- **Changelog** — [0.5.0 → Fixed](../../CHANGELOG.md#050---2026-08-09).

## Decision

**Rich embed cards: server-side oEmbed metadata.** An embed block stored a URL
and rendered `<figure data-url="…"></figure>` — no title, no thumbnail, no
provider. A headless consumer got a naked URL, which in practice meant nothing
rendered at all. Kiln now resolves metadata against a curated provider list
(YouTube, Vimeo, SoundCloud, Spotify, CodePen, Flickr, TED, Bluesky) and
renders a card: link, title, provider, optional thumbnail (#489).

**Off by default; enabling it is egress.** `OEMBED_ENABLED=true` makes the
server issue an outbound request when an editor saves a document containing an
embed a provider claims. `OEMBED_PROVIDERS` can *narrow* the list; adding one
is a code change, because a provider is a host this server dials.

Three decisions are the security of the feature:

- **A registry, not oEmbed discovery.** Discovery means fetching the embedded
  page and following a `<link rel="…oembed">` — i.e. letting *content* choose
  which host the server talks to, from a field any editor can type. The
  endpoint is a constant per provider; the URL only selects which of them is
  asked.
- **The provider's `html` is discarded, not sanitized.** Rendering it means
  trusting a third party with script execution on the delivery origin, or
  maintaining a sanitizer for markup whose purpose is to do what sanitizers
  strip. Cards are built from escaped scalars. The two framed hosts keep the
  canonical-iframe rewrite they already had, and remain the only thing that
  produces an `<iframe>`.
- **Thumbnails are checked against that provider's own CDN**, on the way in
  *and* on any write, because these are ordinary block fields an editor or a
  headless caller can set. `img-src` widens to exactly that list, and only
  when the feature is on.

Resolution runs in an Oban worker, never the save — a provider having a bad
afternoon must not become Kiln having one — and writes through a dedicated
`:set_oembed_metadata` action so it cuts no version, emits no `updated`
webhook, and does not bump `lock_version` into an editor's next autosave.
Artifacts are re-fired deliberately, and only for a published document.

**This required changing what an embed block stores.** The save path used to
run `safe_embed_url/1`, which knows two hosts and *rewrites* them — so a
stored embed URL was a canonical player URL or the empty string, and every
other URL an author pasted was destroyed on save. Storage now keeps what the
author typed (absolute `http(s)` only); whether a URL may be *framed* is a
render-time question both surfaces already asked. An embed block therefore
round-trips its URL for the first time, and a paste of a non-video link is no
longer silently thrown away.

A second review round caught four things worth naming, because each was
invisible from the unit tests:

- **The card still never reached the public site.** `enrich_block/3` had no
  embed clause, so delivery built `%{type, content}` with no title and the
  card branch rendered an empty div — while the fired artifact and every
  preview showed the card correctly. The one surface that matters was the one
  surface still inert.
- **The worker destroyed concurrent edits.** It read the block list, spent
  seconds on an outbound request, then wrote that list back — with the
  optimistic lock deliberately off, so an editor's additions during the fetch
  vanished with no error. Since `:autosave` is one of the enqueuing actions,
  that collision was the normal case. It now fetches first, re-reads, and
  applies metadata to whatever is stored *now*, matching on block id and URL.
- **Changing an embed's URL kept the previous target's card.** Ash merges an
  embedded block by id, so an edit that changes only `url` keeps the old
  title and thumbnail — and a "has no title yet" check never re-resolved. A
  `resolved_url` field now records what the metadata describes; a mismatch
  suppresses the card everywhere (render, search, the LLM surface) *and*
  re-enqueues.
- **Oban's default uniqueness includes `:completed`**, so a URL changed
  within a minute of the last resolve would never re-resolve at all.

Also fixed while here: `safe_embed_url/1` concatenated the video id into a URL
without checking its character set — every render path escapes it, so it was a
latent hazard rather than a live one, but "the id is whatever was in the path"
made that escaping the only line of defence.
