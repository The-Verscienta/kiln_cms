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

## Facts: what a pure check cannot compute

Checks are pure — no database, no network. That is what lets the editor re-run
every one of them on a keystroke, and what stops a third-party check doing
something expensive on the render path.

Some questions still need I/O. "Does this internal link resolve?" is a query per
path. Those answers arrive as **facts**: the caller computes them on whatever
schedule suits it and passes them in.

```elixir
Analyzer.analyze(fields, body, facts: %{link_targets: KilnCMS.Links.Internal.resolve_all(paths, locale, org_id)})
```

```elixir
def check(context) do
  case Context.fact(context, :link_targets) do
    nil -> :n_a          # this caller did no lookup
    targets -> judge(targets)
  end
end
```

**A check reading a fact must handle its absence, and `:n_a` is the honest
answer.** Reporting a pass would claim a verdict nobody computed — a document
whose links were never checked is not a document whose links are fine.

The content editor recomputes `:link_targets` only when the *set of linked
paths* changes, not on every body change and certainly not on every keystroke.

## Broken internal links (#474)

`Kiln.Advisory.Checks.InternalLinks` reports two things, deliberately not one:

| Finding | Severity | Means |
|---|---|---|
| `internal_links_missing` | `:error` | Nothing resolves this path in any state. The link is wrong, or the target was deleted. |
| `internal_links_unpublished` | `:warning` | A real document, not currently served. Publish it, or the author linked a draft too early. |

Delivery cannot tell those apart — both are a 404 to a visitor — but they need
opposite actions, and collapsing them sends an editor hunting for a typo in a
link that is perfectly correct.

A path covered by a redirect is **not** reported. A published rename leaves a
`KilnCMS.CMS.Redirect` behind and delivery serves a 301; flagging that would
report a working feature as a fault, which is the fastest way to make an
advisory panel something authors learn to ignore.

`KilnCMS.Links.Internal` mirrors delivery's resolution order — a leading
supported-locale segment stripped (as `Plugs.SetLocale` does), then flat
`/<prefix>/<slug>`, then the multi-segment path alias, then the redirect table,
with the same default-locale retry delivery performs. A checker with its own
idea of what resolves reports links that work and misses links that don't. It
differs in exactly one way, on purpose: it looks in **every** state, so it can
tell "not published yet" from "gone".

### "I could not resolve it" is not "it is broken"

The resolver only ever reports `:missing` for a path in a namespace it **owns** —
`/<content-prefix>/<slug>`, or a path an alias or redirect matches. Everything
else is `:unknown`, and `:unknown` is never shown to anyone.

That is not caution for its own sake. The router serves far more than content
(`/`, `/blog`, `/search`, `/developers`, `/feed.xml`, every plugin route), and
enumerating it here would be a second copy of the router, wrong the day either
changes. Guessing the other way is worse than not checking: one `:error` grades
a document Poor, so a single "read more on our blog" link would mark every page
on the site as failing, and authors would learn within a day to ignore the panel.

A failed query is `:unknown` too — a transient database blip must not become a
page full of false errors.

**External links are not checked here.** That half of #474 needs outbound
requests, per-domain throttling and a per-org opt-in, and is tracked separately.

## Where things live

| | |
|---|---|
| `Kiln.Advisory` | the behaviour, and `finding/4` |
| `Kiln.Advisory.Context` | fields + body facts, feature-neutral |
| `Kiln.Advisory.Body` | the block-tree walk (headings, images, sentences, links) |
| `Kiln.Advisory.Registry` | discovery, execution, containment, tally |
| `Kiln.Advisory.Checks.*` | feature-neutral checks (headings, image alt, internal links) |
| `KilnCMS.Links.Internal` | resolves a same-origin path the way delivery would |
| `KilnCMS.Seo.Checks.*` | search-specific checks (meta, keyphrase, readability) |
| `KilnCMS.Seo.Analyzer` | aggregates outcomes into the SEO report and grade |

The split between the last two namespaces is deliberate: heading order and
missing alt text are as much accessibility checks as SEO ones, so they sit where
either feature can register them without depending on the other.
