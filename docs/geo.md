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

## Phase 2 (planned)

- **`:llm` fired artifact surface** — a clean, chunked Markdown rendering of each
  document (extends the firing engine's per-surface model; `llms.txt` would then
  link to `.md` versions).
- **Expanded schema.org / JSON-LD** — beyond the current `Article`: `FAQPage`,
  `HowTo`, and for the health domain `MedicalWebPage` + `ClaimReview` (extends
  `KilnCMS.Firing.Engine`'s `:json_ld` composition).
- **Citation / source metadata on claims** — ties into content provenance
  ([#340](https://github.com/The-Verscienta/kiln_cms/issues/340)).
