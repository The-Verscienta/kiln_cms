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
wrappers. `KilnCMSWeb.AccessibilityComponents` is its sibling — same shape,
different sentences, and it delegates any code it doesn't have its own wording
for rather than restating two dozen clauses that would then drift.

## Two panels, one set of checks (#495)

The editor shows an **SEO & scheduling** panel and an **Accessibility** panel.
They are two views over the same registry, not two registries.

That matters because the overlap is large and load-bearing. A skipped heading
level breaks the outline a screen-reader user navigates by *and* the one a
search engine reads; an image with no alt text is a failure in both. Splitting
the panels without splitting the checks is the whole point — an author fixing a
heading should not have to find it twice, and the two panels can never disagree
about what a heading problem is.

Each check says where it belongs:

```elixir
@impl Kiln.Advisory
def lenses, do: [:seo]          # search-only
def lenses, do: [:accessibility] # a11y-only
# omit it entirely for both — the default
```

**The default is both.** A plugin author who never considered the distinction
gets a panel rather than silence, which is the failure that would be hard to
notice.

### When one check's findings don't all belong together

`KilnCMS.Seo.Checks.Readability` reports long sentences, long paragraphs and
hard-to-read prose — all WCAG 3.1.5 territory — alongside thin content, which
is purely a search concern. A per-check lens forces it to pick one panel and be
wrong in the other, so a single finding can narrow past its check:

```elixir
:warning
|> finding(:thin_content, :body, %{count: count, min: @thin_content})
|> lensed([:seo])
```

Reach for that only when it is genuinely true. A check that needs it for every
finding should change its `lenses/0` instead.

### Run once, split after

`Kiln.Advisory.Registry.by_lens/2` filters outcomes that have already run. Running the
registry twice — once per panel — would pay for every shared check twice on
every keystroke, which is most of them. `KilnCMS.Seo.Analyzer.run/3` returns
the un-lensed outcomes for exactly this reason; `analyze/3` is the
already-filtered SEO view for callers that only want one.

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

**External links are not checked here.** Outbound checking needs requests,
per-domain throttling and a per-site opt-in, so it is a scheduled sweep with its
own report at `/editor/links` rather than a check in this panel — see
[Broken link checking](link-checking.md).

## Accessibility checks (#495)

Authoring-time checks, deliberately **not** a frontend overlay widget — those
are [rightly considered harmful](https://overlayfactsheet.com/) by the
accessibility community, because they paper over a page rather than fix it.
What ships here produces findings an author can act on, in the editor, before
anything is published.

| Check | Finding | Severity |
|---|---|---|
| `Checks.ImageAlt` | image with no alt text | error |
| `Checks.Headings` | no headings / skipped level / empty heading | warning |
| `Checks.LinkText` | empty link text | error |
| `Checks.LinkText` | uninformative ("click here") / bare URL as label | warning |
| `Checks.AllCaps` | a run of capitalised words | warning |
| `Seo.Checks.Readability` | long sentences, long paragraphs, hard-to-read prose | warning / info |

Only `link_text_empty` and `images_missing_alt` are errors. The rest are
judgement calls with real exceptions — "read more" under a card heading that
supplies the context is genuinely fine — and an advisory that cries wolf on a
defensible choice is one authors learn to dismiss, at which point it isn't
catching the real ones either.

> **`LinkText` is currently blind to editor-authored content** (#823). It reads
> Portable Text `markDefs`, and the editor's TipTap build has no Link
> extension, so opening a page strips its anchors and the autosave persists
> that. Links written through the API, MCP or an import are checked normally.

Two design notes worth knowing before changing them:

* **`LinkText` matches whole text, never substrings.** "learn more" is a bad
  link; "learn more about invoicing" is a good one. A substring match flags
  both.
* **`AllCaps` needs four consecutive capitalised words** of two letters or
  more. That threshold is the whole design: without it the check flags every
  acronym on a technical page. Words with no cased letters ("2024") are
  *transparent* — they neither start a run nor break one — because treating
  them as lowercase splits "THIS IS A REALLY IMPORTANT NOTICE" in two and lets
  it pass.

The hard enforcement of alt text at publish time is separate and opt-in —
`KilnCMS.CMS.Validations.MediaAltText` (#403). This layer never blocks a save.

## Where things live

| | |
|---|---|
| `Kiln.Advisory` | the behaviour, `finding/4`, `lensed/2` |
| `Kiln.Advisory.Context` | fields + body facts, feature-neutral |
| `Kiln.Advisory.Body` | the block-tree walk (headings, images, sentences, link text) |
| `Kiln.Advisory.Registry` | discovery, execution, containment, tally, `by_lens/2` |
| `Kiln.Advisory.Report` | findings + tally + grade, shared by both panels |
| `Kiln.Advisory.Checks.*` | feature-neutral checks (headings, image alt, internal links, link text, all caps) |
| `KilnCMS.Links.Internal` | resolves a same-origin path the way delivery would |
| `KilnCMS.Seo.Checks.*` | search-specific checks (meta, keyphrase, readability) |
| `KilnCMS.Seo.Analyzer` | builds the context and runs the registry |
| `KilnCMSWeb.SeoComponents` / `KilnCMSWeb.AccessibilityComponents` | one message table each |

The split between the last two namespaces is deliberate: heading order and
missing alt text are as much accessibility checks as SEO ones, so they sit where
either feature can register them without depending on the other.
