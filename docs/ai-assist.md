# AI block assist in the editor

Per-block writing help in the content editor: pick a rich-text block, pick what
you want done to it, get prose back, and accept or throw it away. Six actions —
**Draft**, **Continue**, **Summarize**, **Improve**, **Shorten**, **Expand**.

This is the body-copy half of Kiln's AI surface. The metadata half —
proposing `seo_title`, `seo_description` and `seo_keywords` — is a separate
feature with its own switch; see [SEO analysis and drafting](seo.md).

**Off by default.** A default install renders no assist control and sends
nothing anywhere.

## Enabling it

Set one environment variable to a `req_llm` model spec:

```
ASSIST_MODEL=ollama:llama3.1
```

or configure it directly:

```elixir
config :kiln_cms, KilnCMS.Assist,
  generator: KilnCMS.Assist.Generator.ReqLLM,
  model: "ollama:llama3.1"
```

Both `generator:` and `model:` must be set. `KilnCMS.Assist.enabled?()` tells
you whether they are.

### On-prem (recommended)

`req_llm` carries `ollama` and `vllm` providers, and every provider's
`base_url` is overridable, so pointing Kiln at a model running inside your own
network needs no Kiln code:

```
ASSIST_MODEL=ollama:llama3.1
```

`KilnCMS.Assist.egress?/0` reports whether content actually leaves the
deployment. It resolves the **endpoint host**, not the provider name — naming a
provider `ollama` while pointing its `base_url` at a rented GPU box is egress,
and reporting it as local would be a lie. Only a loopback or private address
counts as local; anything unrecognized is treated as egress.

### A hosted provider

```
ASSIST_MODEL=anthropic:claude-sonnet-5
ANTHROPIC_API_KEY=...
```

Kiln never reads or stores provider API keys. `req_llm` resolves them from its
own environment, so no new secret enters Kiln's config, database or release env
template.

When a hosted provider is configured, Kiln logs a warning at boot and the
editor shows a standing, non-dismissible notice next to the control naming the
provider. The operator chose it; the editor clicking Generate did not.

`ASSIST_GENERATOR` overrides the adapter module if you have written your own.

## Why this is a separate switch from SEO drafting

Setting `SEO_MODEL` does **not** enable block assist, and vice versa. The two
send different things:

| | SEO drafting | Block assist |
|---|---|---|
| Sent | page title, excerpt, headings, body text | one block's text, page title, excerpt, headings, **and the editor's typed instruction** |
| Returned | three short strings | prose for the page body |
| Cadence | once per page | as often as an author likes, per block |

An operator who accepted the first has not thereby accepted the second, so
bundling them would mean enabling one silently enabled another. The same
reasoning keeps `c:KilnCMS.Seo.Generator.describe_image/2` — which would ship
image *bytes* — out of the drafting switch.

What the two features do share is the classification of what leaves the box
(`KilnCMS.LLM`) and the rate-limit mechanism (`KilnCMS.LLM.Budget`), so they
can't drift apart on the questions where drift would mislead an operator.

## What is sent

One block, not the page. `KilnCMS.Assist.Request` is an explicit allow-list:

- the selected block's plain text (truncated to `max_input_chars`);
- the page's title, excerpt and headings — enough context to keep the voice
  consistent with the rest of the page;
- the content type's label and the record's locale;
- the instruction the author typed, if any (truncated to
  `max_instruction_chars`).

No ids, no author, no custom fields, no audience, no other block's prose. A
fifty-block page ships one block.

## Settings

All under `config :kiln_cms, KilnCMS.Assist`:

| Key | Default | What it does |
|---|---|---|
| `generator` | `nil` | Adapter module. `nil` = off. |
| `model` | `nil` | `req_llm` spec, `"provider:model"`. `nil` = off. |
| `temperature` | `0.6` | Warmer than SEO drafting's `0.3`: this drafts prose a person will edit. |
| `max_tokens` | `1200` | Per-response ceiling. |
| `timeout_ms` | `45_000` | Prose takes longer than three metadata strings. |
| `max_input_chars` | `8_000` | Longest block passage sent. |
| `max_instruction_chars` | `500` | Longest author instruction sent. |
| `max_output_chars` | `6_000` | Longest suggestion kept. |
| `per_user_limit` | `{10, 60_000}` | Per-editor bucket — stops a stuck button looping. |
| `per_org_limit` | `{150, 3_600_000}` | The actual spend ceiling. |
| `base_url` | unset | Endpoint override. Reaches the request *and* the egress classification, so it can't silence the warning without moving the bytes. |

Both buckets must pass. They are namespaced separately from SEO drafting's, so
exhausting one feature never silently disables the other.

There is deliberately **no result cache**: a generation is per-block,
per-revision and per-org, and a cache key loose enough to ever hit would be a
cross-tenant leak.

## What is guaranteed regardless of provider

- **Nothing is written without a human click.** The suggestion is shown; the
  author clicks Insert or Replace. This is the primary control, and it holds
  even if a model is compromised or a prompt injection succeeds.
- **The suggestion never travels as markup.** It reaches the browser as a list
  of paragraph *strings* and is applied as TipTap plain-text nodes. A model
  talked into emitting `<script>` produces a paragraph that visibly reads
  `<script>` — which nobody clicks Insert on.
- **Output is constrained, not trusted.**
  `KilnCMS.Assist.Suggestion.normalize/2` runs over every suggestion: tags
  stripped, markdown links collapsed to their label, control and format
  characters removed (NUL, which Postgres raises on; the bidi overrides that
  render text reversed), length clamped.
- **The model gets no tools.** The generator callback takes a struct of strings
  and returns a string. It cannot call Ash actions, read other records, or
  reach the network beyond its own provider.
- **The server never writes the block.** Accepting pushes an event to the
  browser and TipTap applies it as an ordinary, undoable editor transaction.
  Writing prose into the block server-side would force the document back into
  an editor mounted under `phx-update="ignore"`, discarding the author's cursor
  and undo stack and desynchronizing anyone collaborating on it.
- **Prose is generated in the record's locale**, not the admin UI's.

Both the passage and the author's instruction are fenced and labelled in the
prompt. That helps and costs nothing, but it is not a security boundary — the
points above are.

Bare URLs are deliberately left visible as text rather than dropped. In a
`<meta>` tag a URL is pure payload and SEO drafting is right to refuse it; in
body prose "see example.com/spec" is ordinary writing, it creates no link, and
the author reads the paragraph before accepting it.

## Writing your own generator

`KilnCMS.Assist.Generator` is a behaviour; point config at any module
implementing it:

```elixir
defmodule MyApp.AssistGenerator do
  @behaviour KilnCMS.Assist.Generator

  @impl true
  def generate(request, _opts) do
    {:ok, "Some prose grounded in #{request.text}."}
  end
end
```

`request` is a `KilnCMS.Assist.Request`. Return `{:ok, text}`, or
`{:ok, text, usage_map}` if you can report token usage. Whatever you return is
normalized before it reaches the editor, so you cannot accidentally ship markup
or an unbounded string.

## Troubleshooting

**The assist control never appears.** Assist is off. Both `generator:` and
`model:` must be set — check `KilnCMS.Assist.enabled?()`. Note the control is
offered on rich-text blocks only.

**"This block needs at least N characters to work from."** Every action except
Draft works *on* the block's existing text. Use Draft with an instruction to
write a section from scratch.

**"Describe what this section should say, then try again."** Draft is the one
action that requires an instruction — without one there is nothing to ground
the generation in but the page title.

**"The model returned nothing usable."** The response survived nothing after
normalization — usually a model that replied with only a preamble, or only
markup. Try a larger or more instruction-tuned model.

**Generations are slow.** Prose is many more tokens than three metadata
strings. Raise `timeout_ms`, or lower `max_tokens`.
