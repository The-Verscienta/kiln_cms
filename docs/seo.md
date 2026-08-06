# SEO analysis and drafting

Kiln's SEO support has two halves, and they are deliberately independent.

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
  max_input_chars: 12_000,    # body budget; head + tail are kept
  min_words: 50,              # below this, drafting is refused as pointless
  title_max: 60,
  description_max: 160,
  keyword_max: 5,
  per_user_limit: {20, :timer.minutes(1)},
  per_org_limit: {200, :timer.hours(1)}
```

Both rate-limit buckets must pass. The per-user bucket stops a stuck button or
a replayed event; the per-org bucket is the spend ceiling. Neither is an access
control — who may spend at all is decided before the buckets are consulted, by
the update check below.

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
- **Only someone who could save the record can spend on it.** Drafting asserts
  the actor may `:update` this record — the same permission accepting a
  suggestion ultimately needs — before the generator is called, and the control
  isn't rendered otherwise. Reaching the editor takes read access, and read
  access is not enough to consume the org's budget: a reviewer, or an editor
  whose `editable_types` scope excludes this type, gets neither the button nor
  a generation from a pushed event.
- **Drafts are generated in the record's locale**, not the admin UI's.

The body is also fenced and labelled as untrusted data in the prompt. That
helps and costs nothing, but it is not a security boundary — the three points
above are.

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
