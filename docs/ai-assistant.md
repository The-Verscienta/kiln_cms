# AI content assistant

Stretch issue #60. KilnCMS ships a pluggable AI assistant that helps editors
generate and refine content — currently SEO suggestions in the block editor,
with summarize/generate helpers available to any caller. The provider is
configurable, so no vendor is hardcoded.

## Architecture

- **[`KilnCMS.AI.Provider`](../lib/kiln_cms/ai/provider.ex)** — a one-callback
  behaviour (`complete(prompt, opts)`), the seam every provider implements.
- **[`KilnCMS.AI.Echo`](../lib/kiln_cms/ai/echo.ex)** — the default, offline
  provider. Deterministically trims the prompt; needs no API key, so the assist
  UI and tests work out of the box.
- **[`KilnCMS.AI.Anthropic`](../lib/kiln_cms/ai/anthropic.ex)** — calls Claude
  via the Anthropic Messages API over HTTP (Req). Used in production when an API
  key is present.
- **[`KilnCMS.AI`](../lib/kiln_cms/ai.ex)** — the facade editors and code call:
  `generate/2`, `summarize/2`, `seo_description/2`, `seo_title/2`.

## Configuration

Default (offline) — set in `config/config.exs`:

```elixir
config :kiln_cms, KilnCMS.AI, adapter: KilnCMS.AI.Echo, enabled: true
```

Production — `config/runtime.exs` switches to Claude when `ANTHROPIC_API_KEY` is
set:

```bash
ANTHROPIC_API_KEY=sk-ant-...        # enables the Claude provider
ANTHROPIC_MODEL=claude-opus-4-8     # optional; this is the default
```

When the key is set, the runtime config becomes:

```elixir
config :kiln_cms, KilnCMS.AI, adapter: KilnCMS.AI.Anthropic, enabled: true
config :kiln_cms, KilnCMS.AI.Anthropic, api_key: <key>, model: "claude-opus-4-8"
```

Set `enabled: false` to hide the editor assist UI entirely.

### Adding a provider

Implement `KilnCMS.AI.Provider` and point the config at it:

```elixir
defmodule MyApp.AI.OpenAI do
  @behaviour KilnCMS.AI.Provider
  @impl true
  def complete(prompt, opts), do: # ... return {:ok, text} | {:error, reason}
end

config :kiln_cms, KilnCMS.AI, adapter: MyApp.AI.OpenAI
```

## Editor UX

In the block editor's **SEO** panel, each of the SEO title and SEO description
fields has a **Suggest with AI** button. Clicking it generates a suggestion from
the content (title + the saved plain-text body) and fills the field; the editor
can then edit or discard it. The call runs off the request path via
`Phoenix.LiveView.start_async`, so a slow provider never blocks the editor, and
failures surface as a flash without losing the draft. The button is hidden when
the assistant is disabled in config.

> The assist reads the **saved** content (`search_text`), so save the draft
> before generating to include the latest body.

## Cost & privacy

- With the Claude provider, each suggestion is one Messages API call (small
  `max_tokens`); cost scales with content length. The Echo provider is free.
- Content sent to a provider leaves your infrastructure — review the provider's
  data-handling terms before enabling it on sensitive content. The threat model
  ([docs/threat-model.md](threat-model.md)) covers outbound data considerations.

## Future work

- Per-block generate/rewrite actions (the facade already supports arbitrary
  prompts; the UI currently wires SEO only).
- Streaming responses into the editor.
- Tone/length controls and a usage budget.
