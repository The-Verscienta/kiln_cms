# SEO analysis and drafting

Kiln's SEO support has two halves, and they are deliberately independent.
(A third, smaller piece — [per-type default patterns](#per-type-default-patterns)
— needs neither.)

| | Analysis | Drafting |
|---|---|---|
| What it does | Scores the page and lists fixable findings | Proposes a title, description and keywords |
| Configuration | None | Required (off by default) |
| Network | None | Whatever provider you point it at |
| Availability | Every install | Only when configured |

Drafting here proposes *metadata*. Writing help for the page **body** —
draft, summarize, rewrite a block — is a separate feature with its own switch;
see [AI block assist in the editor](ai-assist.md).

**The analysis is always on.** It needs no configuration, no model and no
network, and it is what most of the value lives in — the traffic light, the
length checks, the keyphrase and readability advice. If you never read past
this paragraph, the feature still works.

## Analysis

The panel lives in the content editor's **SEO & scheduling** section: a grade
in the header (`Good` / `Needs work` / `Poor`, driven by severity — advisory
notices never turn it amber) plus an "n of m checks passing" counter and a list
of findings. Nothing it reports ever blocks a save; findings are advice.

Checks cover meta title and description lengths, focus-keyphrase presence in
the title, slug, opening paragraph and description, keyphrase density, content
length, heading presence and level order, images missing alt text, the social
image, and readability.

Two honest limitations:

- **Keyphrase and readability checks are English-only.** Word comparison runs
  through the same stop-word stripping the slug derivation uses, which is
  English, and the Flesch syllable heuristic is meaningless in other languages.
  For a non-English record those checks report "not applicable" rather than
  confidently wrong advice. Length and presence checks are language-neutral and
  always run.
- **Checks with nothing to judge stay neutral.** A brand-new empty draft shows
  no findings rather than a wall of red.

Implementation: `KilnCMS.Seo.Analyzer` (pure) over `KilnCMS.Seo.BodyStats` (the
body walk). Findings carry codes and numbers, never prose — messages live in
`KilnCMSWeb.SeoComponents.finding_message/2`, so they translate.

## Per-type default patterns

Neither half above writes anything. If you want every record of a type to get a
consistent `<title>` without an author typing one, give the type a **pattern**:

```
Editor → Content types (/editor/types) → a type → Default SEO title
```

`[title] | [site-name]` is the usual one. Compiled types declare the same thing
in code:

```elixir
use KilnCMS.CMS.Content,
  type: :post,
  seo_title_pattern: "[title] | [site-name]",
  seo_description_pattern: "[excerpt]"
```

Tokens are the same bracket syntax the slug and path-alias patterns use, and
validated the same way — a typo like `[titel]` is rejected when you
save the type, not discovered in a search result:

| Token | Expands to |
|---|---|
| `[title]` | The record's title, as written |
| `[excerpt]` | The excerpt, on types that have one |
| `[category]` | The category's **name** (not its slug) [^teaser] |
| `[site-name]` | Your site name, from white-label branding |
| `[yyyy]` `[mm]` `[dd]` | Publish date, else scheduled date, else created |
| `[field:<name>]` | A custom field's value, as written |

Unlike a slug, nothing is slugified: this is prose, and the separators are
whatever you typed between the brackets. A token that expands to nothing takes
its neighbouring separator with it, so `[title] | [category]` on an
uncategorized record renders `Kiln guide`, not `Kiln guide | `.

**A pattern is a default, never an overwrite.** Three consequences worth
knowing:

- An author who types a title keeps it. The pattern only fills a field the
  record left blank.
- Nothing is written to the record — the expansion happens when the page is
  rendered. So changing a type's pattern re-titles every record that never had
  one, immediately, with no backfill and nothing to re-publish.
- The editor's SEO panel scores what the record itself holds. A record relying
  on the pattern shows an empty title there and the length check says so, which
  is the honest reading: the pattern is the type's, not the record's. Type a
  title if you want it analysed.

The export (and the JSON:API/GraphQL representation of a record) also reports
the stored fields, for the same reason — a patterned title re-imported as an
author-typed one would be a silent override.

Implementation: `KilnCMS.Seo.Pattern` (the vocabulary) and
`KilnCMS.Seo.Patterns` (resolution at render time).

[^teaser]: On a **paywall teaser** `[category]` expands to nothing, because that
    read is pinned to a fixed set of columns with no relationships — the same
    restriction that keeps the block tree away from a teaser. The separator
    beside it drops out with it, so the teaser's title is shorter than the full
    page's, never malformed.

## Drafting (optional)

Off by default. With `generator: nil` no module is called and nothing leaves
the deployment.

### On-prem (recommended)

Run a model next to Kiln and no content crosses the network boundary:

```bash
# Anything req_llm's `ollama` or `vllm` provider can reach.
SEO_MODEL=ollama:llama3.1
```

The environment variables are read in the production/release branch of
`config/runtime.exs`, alongside `MEILI_URL` and the rest — so for dev or test,
configure it in a config file instead:

```elixir
config :kiln_cms, KilnCMS.Seo,
  generator: KilnCMS.Seo.Generator.ReqLLM,
  model: "ollama:llama3.1"
```

Point `req_llm` at a non-default endpoint with its own provider configuration;
every provider's `base_url` is overridable, so an OpenAI-compatible local
server works without any Kiln code.

### A hosted provider

```bash
SEO_MODEL=anthropic:claude-sonnet-5
ANTHROPIC_API_KEY=...
```

**This sends content to a third party.** Specifically: the page title, its
excerpt, its headings, any existing SEO values, and the body text (truncated to
`max_input_chars`, keeping the opening and closing passages). Kiln announces
this at boot:

```
[warning] SEO drafting is enabled against anthropic (anthropic:claude-sonnet-5).
Page title, excerpt and body text are sent to that provider when an editor asks
for suggestions. Add it to your DPA's subprocessor list, or point SEO_MODEL at a
local endpoint (e.g. ollama:llama3.1) to keep content in the deployment.
```

The editor also shows a standing notice next to the suggest control, because
the operator made this choice and the editor clicking the button did not. If you
enable a hosted provider, add it to your DPA's subprocessor list — see
`docs/data-flows.md`.

**Kiln never reads or stores provider API keys.** `req_llm` resolves them from
its own configuration and environment, so no new secret enters Kiln's config,
database or release environment.

### Settings

```elixir
config :kiln_cms, KilnCMS.Seo,
  generator: nil,             # nil ⇒ drafting off entirely
  model: nil,                 # "provider:model" spec for req_llm
  temperature: 0.3,
  max_tokens: 700,
  timeout_ms: 20_000,
  max_input_chars: 12_000,    # body budget; head + tail are kept. Enforced
                              # again after fence-neutralization, which can
                              # expand a rule-heavy body several-fold.
  min_words: 50,              # below this, drafting is refused as pointless
  title_max: 60,
  description_max: 160,
  keyword_max: 5,
  per_user_limit: {20, :timer.minutes(1)},
  per_org_limit: {200, :timer.hours(1)},
  unattended_share: 0.5       # of per_org_limit, for callers with nobody
                              # waiting on them (automation reactions)
```

Both rate-limit buckets must pass. The per-user bucket stops a stuck button or
a replayed event; the per-org bucket is the actual spend ceiling.

**Unattended callers stop early, so people keep a reserve.** The
`suggest_metadata` automation reaction ([`docs/automation.md`](automation.md))
draws on the same per-org budget as the editor's button, so a busy rule could
exhaust the hourly allowance and leave every editor with a rate-limit error
caused by something they cannot see. A caller marked unattended may only
proceed while the org has spent **less than `unattended_share` of its window** —
counting every caller's spend, not just automation's. At the defaults that
leaves at least 100 of the 200 available to a person at any moment in the hour.

Reading the shared counter is the point. A sub-bucket that counted only
unattended calls would still let a background rule take the last unit when
editors sat at 199 of 200 and automation had spent nothing — which is the
failure this exists to prevent. The consequence is that automation's room
shrinks as editors work, which is the intended priority.

`unattended_share: 0.0` keeps automation off this budget entirely, and reports
itself as `{:error, :unattended_disabled}` rather than as a rate limit an
operator would wait out. `1.0` restores the pre-#943 shared bucket. A value
that isn't a number between 0 and 1 — `50`, meaning percent, is the natural
mistake — fails closed to 0 and logs which key was wrong.

There is deliberately **no draft cache**: a draft is per-document,
per-revision and per-org, and a cache key loose enough to ever hit would be a
cross-tenant leak.

## What is guaranteed regardless of provider

- **Nothing is written without a human click.** Drafting proposes; an editor
  accepts each field. This is the primary control, and it holds even if a model
  is compromised or a prompt injection succeeds.
- **Output is constrained, not trusted.** Every draft goes through
  `KilnCMS.Seo.Draft.normalize/1`: collapsed to a single line, markup stripped,
  hard-truncated to the configured maxima, and any value still carrying a URL
  is dropped rather than offered. Drafted text lands in `<meta>` tags on your
  public site, so a smuggled link is exactly what an injection would be after.
- **The model gets no tools.** The generator callback takes strings and returns
  strings. It cannot call Ash actions, read other records, or reach the network
  beyond its own provider.
- **Drafts are generated in the record's locale**, not the admin UI's.

Everything the author controls — the title, the excerpt, the headings, the
existing SEO values and the body — is fenced and labelled as untrusted data in
the prompt, and passed through `KilnCMS.LLM.Fence` so that nothing inside a
region can close it early. The labelled fields and the body get *separate*
regions, so a body line reading `Current SEO title: …` cannot pass for the real
field. That helps and costs nothing, but it is not a security boundary — the
three points above are. `KilnCMS.LLM.Fence` is where that defence lives for all
three of Kiln's prompt builders; extend it there rather than per feature.

## Writing your own generator

`KilnCMS.Seo.Generator` is a behaviour; point config at any module implementing
it:

```elixir
defmodule MyApp.SeoGenerator do
  @behaviour KilnCMS.Seo.Generator

  @impl true
  def draft(document, _opts) do
    {:ok, %KilnCMS.Seo.Draft{seo_title: "…", seo_description: "…", seo_keywords: ["…"]}}
  end
end
```

`document` is a `KilnCMS.Seo.Document` — an explicit allow-list of content
fields, already truncated. Whatever you return is normalized before it reaches
the editor, so you cannot accidentally ship an over-long or markup-bearing
value.

## Troubleshooting

**The suggest control never appears.** Drafting is off. Both `generator:` and
`model:` must be set; check `KilnCMS.Seo.enabled?()`.

**Drafts fail against a local model.** Small models often lack the
tool-calling or JSON-schema support that provider-native structured output
needs. The adapter already falls back to asking for plain JSON and recovering
the object itself, so this usually still works — but a model that cannot follow
a formatting instruction at all will return `{:error, :unparsable}`. Try a
larger or more instruction-tuned model.

**`{:error, :too_short}`.** The body is under `min_words`. Generating metadata
for a near-empty page burns tokens to hallucinate, so it is refused before
reaching the provider.

**Spend.** Every generation emits `[:kiln_cms, :seo, :draft, :stop]` telemetry
carrying token usage, model, provider and outcome — see `docs/observability.md`.
