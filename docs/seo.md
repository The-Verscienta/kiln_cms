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

`[category]: [title]` is a typical one. Compiled types declare the same thing
in code:

```elixir
use KilnCMS.CMS.Content,
  type: :post,
  seo_title_pattern: "[category]: [title]",
  seo_description_pattern: "[excerpt]"
```

**Don't put `[site-name]` in a title pattern.** The layout already appends
` · <your site name>` to every page title, so `"[title] | [site-name]"` renders
`Sourdough basics | Acme · Acme`. The token exists for description patterns and
for the rare title that needs the name somewhere other than the end.

Tokens are the same bracket syntax the slug and path-alias patterns use, and
validated the same way — a typo like `[titel]` is rejected when you
save the type, not discovered in a search result:

| Token | Expands to |
|---|---|
| `[title]` | The record's title, as written |
| `[excerpt]` | The excerpt, on types that have one |
| `[category]` | The category's **name** (not its slug) |
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
  rendered, and the page's ETag covers the resolved values. So changing a
  type's pattern re-titles every record that never had one, immediately, with
  no backfill and nothing to re-publish.
- The editor's SEO panel scores what the record itself holds. A record relying
  on the pattern shows an empty title there and the length check says so, which
  is the honest reading: the pattern is the type's, not the record's. Type a
  title if you want it analysed.

**Patterns reach every surface that renders a description.** The delivered
HTML page (`<title>`, meta description, Open Graph and Twitter tags, inline
JSON-LD), and also: RSS/Atom/JSON Feed summaries, the `.ics` `DESCRIPTION`, the
event index's `index.json`, `llms.txt`, auto-posted social text, the ActivityPub
`Note` summary, the fired `:json_ld` artifact, and the preview/webhook payload.
A document does not describe itself one way on its own page and another way in
the feed that links to it.

Surfaces that report a record's fields as **stored data** still report the
stored ones, and deliberately: the export (#487) and the version history. A
patterned title re-imported as an author-typed one would be a silent override.

The headless read APIs report both. `seo_title` / `seo_description` are the
columns — blank means nobody typed one — and `effective_seo_title` /
`effective_seo_description` are what a renderer should print. The
preview/webhook payload carries both for the same reason.

Implementation: `KilnCMS.Seo.Pattern` (the vocabulary), `KilnCMS.Seo.Patterns`
(resolution) and `KilnCMS.CMS.Calculations.EffectiveSeo` (the two calculations,
which carry their own tokens' data dependencies into any read that names them).

### On a paywall teaser, some tokens go quiet

A gated document's teaser is read through a pinned set of columns with no
relationships and no `custom_fields` — the same restriction that keeps the block
tree away from a teaser, and widening it for these two tokens would widen it for
every other consumer of that record too. So on a teaser (and on a passphrase
lock page) `[category]` and `[field:<name>]` expand to nothing, and the
separator beside them drops out with them. The teaser's title is shorter than
the full page's, never malformed.

The teaser's *visible* summary is unaffected either way: that stays the
author's own excerpt or description, never a pattern, because it is body copy
a locked-out reader reads rather than a meta tag.

### On a fired artifact, from the next publish

The `:json_ld` surface is a stored artifact, fired when a document is published,
and so is the `social` object on the `:json` surface
([Link previews](headless-consumer-guide.md#link-previews-the-social-object)).
Editing a type's pattern re-titles every *page* at once, but an artifact already
on disk keeps the values it was fired with until that document is published
again or re-fired (`mix kiln.refire_all`, or `KilnCMS.Firing.Sweep.run/0` on a
release). Stale, in other words, where it used to be permanently wrong.

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

**Kiln never reads or stores the operator's provider API keys.** `req_llm`
resolves them from its own configuration and environment, so no new secret
enters Kiln's config, database or release environment.

A site admin can instead give the site its own provider, key and model at
`/editor/site-ai`; that site then uses it and nothing of the operator's. See
[Per-site provider](ai-assist.md#per-site-provider).

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

## `security.txt`

Next to `robots.txt` and `sitemap.xml`, each site can serve
**`/.well-known/security.txt`** ([RFC 9116](https://www.rfc-editor.org/rfc/rfc9116)):
where a security researcher reports a vulnerability in that site.

```
Editor → Configure → Organization → Security contact (/editor/security-txt)
```

An admin sets one or more **contacts** (`mailto:`, `https://` or `tel:`,
preferred first) and an **expiry date**, both required by the RFC, plus
optionally a disclosure **policy** URL, **preferred languages**, an
**encryption** key (`https://` URL or `openpgp4fpr:` fingerprint) and an
**acknowledgments** page. `Canonical` is not a setting: it is the site's own
URL, derived from the request's host, so each tenant's file names its own host
and a site that moves to a custom domain follows at once.

- **Per site, no deployment default.** A contact is a promise that someone
  reads it, so the operator cannot make one on every tenant's behalf. A site
  with no contact answers **404**, which RFC 9116 reads as "no security.txt".
- **Expiry.** The page warns when the date has passed, is within 30 days, or
  is more than the RFC's recommended year away. A past date cannot be saved,
  but a saved one lapses; an expired file is still served (a stale contact
  beats none), and researchers are told to treat it as stale, so renew it.
- **One line per value.** The file is `Field: value` lines, so a line break in
  a value would forge a field. Values are held to one line of printable ASCII
  when saved and again when rendered.
- `/security.txt` redirects (301) to the `.well-known` path. The response is
  `text/plain; charset=utf-8`, rate-limited like `robots.txt` (`:probe`), and
  cached per site for five minutes server-side, busted on save.

Only admins can edit it (`KilnCMS.CMS.SiteSecurityTxt`); the file, and the row
behind it, are public.

## Robots: `noindex` and `nofollow`

Each document carries two flags, **noindex** and **nofollow** (#2256), both off
by default. They are sent as `<meta name="robots">` and an `x-robots-tag`
response header (one helper builds both, so they agree) when either is set.

`noindex` also removes the document from the discovery surfaces Kiln
generates, so the site does not advertise a page it asks crawlers to skip:

- `/sitemap.xml` and `/news-sitemap.xml`
- `/llms.txt`
- every feed: the site feed, per-type, category and tag feeds (Atom and JSON)

`nofollow` on its own changes nothing in those lists; a nofollow-only document
stays listed.

The flags are an instruction to crawlers, not a delivery switch. The document is
still served, and still appears in the sync/change feed, the fired artifacts,
the static export, JSON:API and GraphQL, each carrying the flags so a separate
frontend can honour them.

How fast a crawler may fetch pages is a separate setting: search engines get
the browser rate limit by default, and a site admin can lower it at
**Sign-in & access → Bot budgets**; see [bot-budgets.md](bot-budgets.md).

The flags are part of the document's working copy: while a published document
has a pending working copy, changing them takes effect on the live page when
the working copy is published, like any other field.

In the editor, both flags are checkboxes in the SEO section beside the canonical
URL. They follow the same field grants and soft locks as the canonical URL: an
editor whose grant leaves them out cannot change them.

The SEO panel also carries an advisory warning, `noindex_nav_linked`, when a
published document is hidden from search but an enabled menu item links to it.
"Enabled" is the same test the structure view's "not in any menu" badge uses
(`KilnCMS.CMS.Menus.linked_content_ids/1`): the item is visible, and so is every
ancestor up to a root. It is a prompt to confirm, not a block; `nofollow` alone
never triggers it. The menu lookup is one read per editor session and document,
and is skipped for drafts.

### Per-type defaults

A content type can start its new documents with either flag on: the
`noindex_default` / `nofollow_default` options of `use KilnCMS.CMS.Content` for a
compiled type, or the two checkboxes on the type's page under **Content types**
for an admin-defined one. A flag takes the default only when the create does not
name it, so an explicit `false` (or `true`) from an editor, the API or an import
always wins. Duplicates and translations copy the source document's flags and
ignore the default; an editor whose field grant leaves the flags out still gets
them copied, so a copy never makes a hidden page indexable. Defaults are not retroactive: documents that already exist
keep what they have, and changing a default touches only documents created
afterwards.

## Link previews: Open Graph and X (Twitter) cards

When someone shares a link, the app they share it in (X, Slack, LinkedIn,
iMessage, Facebook) builds the preview card from tags in the page's `<head>`.
Every page Kiln renders carries two sets: Open Graph (`og:*`), which most apps
read, and the X (Twitter) Card (`twitter:*`), which X reads first (#164,
#2258). Both sets come from one resolution (`KilnCMSWeb.Layouts.social_meta/1`),
so the title, description and image in one always match the other.

| Tags | Value | Left out when |
|---|---|---|
| `og:title`, `twitter:title` | The page's **SEO title**, else its title. A type's [default pattern](#per-type-default-patterns) fills a blank SEO title. A page with no title of its own (the stock home page) gets the site name. | Never |
| `og:description`, `twitter:description` | The page's **SEO description**, or its type's pattern | There is no description |
| `og:image`, `twitter:image` | The page's **Social image**, else the site's **Default social image** (Branding) | Neither is set |
| `twitter:card` | `summary_large_image` when there is an image (the page's or the site's), else `summary` | Never |
| `twitter:site` | The site's **X (Twitter) username** (Branding), as `@handle` | The username is blank |

A tag with no value is left out rather than sent empty: no page carries
`content=""`, which some apps read as "this page has no title" instead of
falling back to the next tag. `og:type`, `og:url`, `og:locale` and
`og:locale:alternate` are unchanged. The same tags are on a gated post's
teaser and on a passphrase lock page, built from the teaser's fields.

**Images are always absolute, on the site's own host.** A Social image picked
from the media library is stored as a site-relative path (`/uploads/…`), and
a preview bot fetching the page cannot resolve that. Kiln prefixes the site's
own address: its custom domain if it has one, else its subdomain of
`TENANT_BASE_HOST`, else `PUBLIC_BASE_URL` for the default site. That applies to
the page's own image, the Default social image and the page's JSON-LD `image`
alike. A full
`https://` URL is used as typed. A relative image Kiln has no site to resolve
against is left out rather than put on the wrong host.

**There are no separate "social" override fields.** The SEO title, SEO
description and Social image in the editor's **SEO & scheduling** section are
the overrides: what a search result shows and what a link preview shows are the
same claim about the page, and a second set of fields would let them drift
apart with nothing to say which is current. To give a page a different preview
title, change its SEO title.

Two tags are not emitted yet: `twitter:creator` (the author's own account, which
needs a per-author handle) and `og:image:alt` / `twitter:image:alt` (the Social
image stores no alt text).

### Show your site's X account on link previews

`twitter:site` names the X account a card is credited to. It is set per site,
by a site admin; there is no environment variable or instance-wide default, so
one site's handle never appears on another site's pages.

1. In the console, open **Delivery → Branding** (`/editor/branding`). You need
   to be an admin of this site; editors and viewers can't open the page.
2. In the **Identity** section, find **X (Twitter) username**, below
   **Default social image**.
3. Type the account. Any of these work: `kilncms`, `@kilncms`, or the
   profile URL copied from the browser, such as `https://x.com/kilncms`,
   `https://twitter.com/kilncms/` or `https://x.com/kilncms?s=21`
   (`www.` and `mobile.` hosts are accepted too).
4. Click **Save branding**. The page reloads with "Branding saved." and the
   field shows the stored form, `@kilncms`.
5. Check a page. Fetch any public page and look for the tags:

   ```bash
   curl -s https://www.example.com/blog/hello-world | grep -E 'og:|twitter:'
   ```

   For a post with an SEO title, an SEO description and a Social image, on a
   site whose username is `@kilncms`:

   ```html
   <meta property="og:title" content="Hello, world">
   <meta property="og:description" content="Our first post.">
   <meta property="og:image" content="https://www.example.com/uploads/hello.png">
   <meta property="og:type" content="article">
   <meta property="og:locale" content="en">
   <meta property="og:url" content="https://www.example.com/blog/hello-world">
   <meta name="twitter:card" content="summary_large_image">
   <meta name="twitter:site" content="@kilncms">
   <meta name="twitter:title" content="Hello, world">
   <meta name="twitter:description" content="Our first post.">
   <meta name="twitter:image" content="https://www.example.com/uploads/hello.png">
   ```

   To see the card itself, paste the link into a new post on X (the preview
   appears in the composer) or into a Slack message. Apps cache previews,
   often for days, so a link shared before the change may keep its old card.

To remove the username, clear the field and save; **Reset to defaults**
clears it along with the rest of the branding.

What can go wrong:

- **"must be an X (Twitter) username like @kilncms"**, in an error banner,
  and nothing is saved. The value is not 1 to 15 letters, digits or
  underscores (`@kiln-cms`, a 16-character name, a space), or it is a URL
  that isn't an X profile: another site, a post (`https://x.com/kilncms/status/1`),
  or one of X's own pages such as `home`, `explore`, `search`, `settings` or
  `i/…`. Those names are refused as bare handles too.
- **`twitter:site` appears twice.** A site that added the tag by hand under
  **Code injection** now gets it from Branding as well. Remove the one in
  Code injection.
- **No `twitter:site` on an error page.** Pages served before Kiln knows which
  site the request is for (some error pages) carry no site handle and no
  Default social image, rather than another site's.

## Google News sitemap

`/news-sitemap.xml` is the sitemap Google News reads beside `/sitemap.xml`.
Every `<url>` carries a `<news:news>` element with the publication name (the
site name from branding), the language (the record's locale as an ISO 639
code; `zh-cn` or `zh-tw` for Chinese), the publication date and the title.

A content type is included when its schema.org type is **`NewsArticle`**:
`schema_org_type: "NewsArticle"` on a compiled type, or the schema.org type
setting on a dynamic one. That is the whole opt-in, and `robots.txt` lists
the news sitemap once a type has it.

Google's limits apply: only articles published in the **last 48 hours**,
newest first, at most **1,000** URLs. Like the feeds, it lists only published
records whose audience is public. It is cached per site for five minutes and
dropped on every publish and unpublish, so a retracted article is gone on the
next request.
