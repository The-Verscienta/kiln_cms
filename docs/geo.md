# GEO — Generative Engine Optimization

Structuring published content so LLMs and answer engines (ChatGPT, Perplexity,
Google AI Overviews) can discover and cite it accurately. The GEO analogue of
SEO ([issue #357](https://github.com/The-Verscienta/kiln_cms/issues/357)).

**Honest caveat:** GEO is an unsettled discipline. These features maximize
*citability* (structure, discoverability, clean surfaces); they do not guarantee
that any given engine cites you.

## Phase 1: `llms.txt`

Kiln serves **`GET /llms.txt`** — a Markdown index of published content following
the emerging [llmstxt.org](https://llmstxt.org) convention (the LLM analogue of
`sitemap.xml`). It lets answer engines find the site's canonical content in one
clean, structured file:

```markdown
# KilnCMS

> Published content from KilnCMS, indexed for language models (see https://llmstxt.org).

## Pages

- [Welcome to KilnCMS](https://example.com/welcome): A world-class, Elixir-native headless CMS.

## Posts

- [Hello, World](https://example.com/blog/hello-world)
```

Behaviour:

- **Published, default-locale records only.** Uses the same `authorize?: true`
  read and `KilnCMS.CMS.ContentTypes` discovery as the sitemap, so drafts and
  gated content never appear; dynamic types (D17) are included.
- **Grouped by content type** (Pages, Posts, and any custom type), with each
  entry's title, public URL, and `seo_description` when set.
- **Cached** under one aggregate key (`KilnCMS.Cache.llms_key/0`, 5-minute TTL),
  busted on every publish/unpublish and type change — exactly like the sitemap.
- **Bounded** to 10,000 entries so the per-request scan stays cheap.
- Served on the rate-limited `:probe` pipeline alongside `sitemap.xml` /
  `robots.txt`.

Implementation: `KilnCMSWeb.LlmsController`, route in `router.ex`, cache helpers
in `KilnCMS.Cache` (`llms_key/0`, `bust_llms/0`).

## The `:llm` surface (Phase 2, shipped)

Every document now fires a fourth surface, **`:llm`** — a clean, chunked
Markdown rendering (`KilnCMS.Firing.LlmMarkdown`): the title as `#`, heading
blocks as real `##…` headings, everything else as its plain-text projection,
blocks separated by blank lines so each is a naturally chunkable passage. A
block module may export an optional `to_markdown/1` for a richer rendering.

- Delivered raw as `text/markdown` at
  `GET /api/content/:type/:slug?surface=llm` (same immutable-artifact,
  cache-and-ETag path as the other surfaces).
- `llms.txt` links each entry's `([md](…?surface=llm))` form, per the
  llmstxt.org "markdown versions" convention.
- Included in static export (`llm.md`).
- **Deploy note:** content published before this feature has no `:llm`
  artifact until re-fired — run a re-fire sweep (or re-publish) for full
  coverage; the delivery route answers 503-retryable for a missing artifact
  as usual.

## Later phases

- **Expanded schema.org / JSON-LD** — beyond the current `Article`: `FAQPage`,
  `HowTo`, and for the health domain `MedicalWebPage` + `ClaimReview` (extends
  `KilnCMS.Firing.Engine`'s `:json_ld` composition).
- **Citation / source metadata on claims** — ties into content provenance
  ([#340](https://github.com/The-Verscienta/kiln_cms/issues/340)).
