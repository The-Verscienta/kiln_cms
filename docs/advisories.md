# Editorial advisories

The content editor shows **advisories**: non-blocking observations about the
content being edited. The SEO description is too short, a heading level was
skipped, an image has no alt text. They never prevent a save — they are advice,
and the author decides.

This is the shared framework behind those panels (#476, #495). It exists so
that search analysis and accessibility checking don't each grow their own body
walk, their own severity vocabulary, and their own copy of the heading-order
check.

## Writing a check

A check is a module implementing `Kiln.Advisory`:

```elixir
defmodule MyApp.Advisories.MissingByline do
  use Kiln.Advisory

  @impl Kiln.Advisory
  def check(%{fields: %{byline: ""}}), do: finding(:warning, :missing_byline, :byline)
  def check(_context), do: :ok
end
```

Register it from a plugin, exactly as you would a block or a field type:

```elixir
@impl Kiln.Plugin
def advisories, do: [MyApp.Advisories.MissingByline]
```

Core checks are configured instead:

```elixir
config :kiln_cms, Kiln.Advisory, checks: [...]
```

### Three outcomes

`check/1` returns `:ok`, `:n_a`, or a `Kiln.Advisory.Finding` — or a list, for a
check that reports on several things.

`:n_a` matters more than it looks. A brand-new page has no body, so body checks
have nothing to say; reporting them as failures greets the author with a wall of
red. `:n_a` also keeps the "9 of 12 checks passing" counter honest, because a
check with nothing to judge is neither a pass nor a failure.

### Findings carry codes, not sentences

```elixir
finding(:warning, :seo_description_short, :seo_description, %{length: 34, min: 70, max: 160})
```

The `args` are what a message interpolates; the sentence lives in the web layer
as `gettext` clauses. That keeps checks free of any web or Gettext dependency —
they are pure functions — and it is what lets one finding render in every
locale. `field` names the input the advisory is about, which is how the editor
knows to show a slug advisory next to the slug input rather than only in the
panel.

Findings that name specific blocks (images missing alt text) carry
`args.indexes`; the editor turns those into jump links.

### Checks must be pure and fast

They run on **every keystroke** in the content editor. No database, no network,
no file IO. The expensive part — walking the block tree — is done once per body
change by `Kiln.Advisory.Body` and handed to every check in the context, so a
check should be comparing values, not re-deriving them.

### A raising check is contained

`Kiln.Advisory.Registry` drops and logs a check that raises, and runs the rest.
Losing one advisory is a far better outcome than losing the author's session.

Be aware of the flip side when developing: a check that raises shows up as a
*missing* advisory rather than an error. If a finding you expect isn't
appearing, check the logs before assuming the logic is wrong.

## Rendering

`KilnCMSWeb.AdvisoryComponents` renders findings — severity tone and icon, the
grade pill, the "n of m" counter, jump links. It takes a `message_fn`, so a new
panel supplies only its own code-to-sentence table:

```heex
<.advisory_findings findings={@report.findings} message_fn={&my_message/1} />
```

`KilnCMSWeb.SeoComponents` is exactly that: the SEO message table plus two thin
wrappers. An accessibility panel would be the same shape.

## Where things live

| | |
|---|---|
| `Kiln.Advisory` | the behaviour, and `finding/4` |
| `Kiln.Advisory.Context` | fields + body facts, feature-neutral |
| `Kiln.Advisory.Body` | the block-tree walk (headings, images, sentences, links) |
| `Kiln.Advisory.Registry` | discovery, execution, containment, tally |
| `Kiln.Advisory.Checks.*` | feature-neutral checks (headings, image alt) |
| `KilnCMS.Seo.Checks.*` | search-specific checks (meta, keyphrase, readability) |
| `KilnCMS.Seo.Analyzer` | aggregates outcomes into the SEO report and grade |

The split between the last two namespaces is deliberate: heading order and
missing alt text are as much accessibility checks as SEO ones, so they sit where
either feature can register them without depending on the other.
