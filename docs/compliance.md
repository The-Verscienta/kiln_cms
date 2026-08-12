# Editorial claim checking

The content editor can show a **Compliance** panel: the phrases in a document
that a regulator, a clinic's counsel, or a house style guide would want a second
look at before it goes live. "FDA approved". "No side effects". "Guaranteed
results".

This is the compliance third of #377, and it is built on the same machinery as
the SEO and accessibility panels — see [Editorial advisories](advisories.md).
Everything here is **off by default**.

## Turning it on

Go to **Claim checking** in the console (`/editor/compliance`, admin only). A
site that has not opted in gets an explanation and a button rather than an empty
form — which is the page's other job, since the editor renders no Compliance
panel at all while the feature is off, and before this page existed nothing in
the admin UI said the feature was there.

Everything on that page belongs to **the site you are on** (#857):

| Setting | Effect |
|---|---|
| Show the Compliance panel | Whether the checks run and the panel appears. Off, both checks report `:n_a` and the panel never renders. |
| Refuse to publish… | Whether an `:error`-severity match **refuses the publish**. Off, everything is advice. **Requires the panel to be on** — on its own it is inert. |
| Also use the rules this deployment ships | Whether the operator's rules (the shipped pack unless they replaced it) apply here. |
| Phrases to flag | This site's own claim vocabulary, one per line. |
| What a match on these phrases means | The severity those phrases carry — only *blocking* can refuse a publish. |
| Text every body must contain | The required disclaimer. Blank inherits the operator's. |

The first two are separate switches on purpose, but they are not independent:
the gate is read through the panel switch, so setting it alone does nothing.
Most publications want the panel long before they want a gate, and turning a
claims vocabulary into a hard publish refusal is a decision someone should make
deliberately.

### The operator layer underneath

A site with no saved settings inherits the deployment-wide config, which is
what a single-tenant install can use on its own:

```elixir
config :kiln_cms, KilnCMS.Compliance,
  enabled: true,
  require_at_publish: false,
  disclaimer: nil,
  rules: :default
```

`KilnCMS.Compliance.Settings` resolves the two layers, most specific first. The
difference between *inherit* and *this site said so* is whether the site has a
row at all: **Save** writes one, **Use the operator defaults** drops it. The one
exception is the disclaimer, where blank means inherit — a text box has no third
state, and an operator's required disclaimer dropped by an admin tabbing past an
empty field would be a compliance requirement lost by accident.

This layering is why the feature is per-site and not per-deployment. A claims
vocabulary is a statement about one publication's voice and jurisdiction, and
`require_at_publish` is a hard refusal: while both lived only in config, one
clinic deciding that "cures" cannot ship refused every other site's publishes on
the same instance, and a tenant that wanted the panel *off* could not turn it
off either.

### When the settings row cannot be read

A rolling deploy before the table exists, a pool timeout: the advisory settings
fall back to the operator config, and the **publish gate is forced off**
(`KilnCMS.Compliance.Settings.unavailable/0`). The gate is the one axis where
guessing wrong turns a transient read error into a site that cannot publish at
all — and it would be refusing on a vocabulary nobody could confirm, since the
site's own rules are exactly what could not be read.

## Why this is an advisory, not an agent

#377 frames its three boxes as automation reactions — background agents that
inspect content and act on it. For claim checking that shape is wrong twice
over.

A claim is a judgement about **meaning**, and no phrase list can make it. "This
herb does not cure cancer" contains the phrase *cure cancer* and is a perfectly
responsible sentence. "Widely regarded as clinically proven" is a claim wearing
a hedge. Every honest implementation surfaces the phrase and asks a human — and
the human is already sitting in the editor. Routing that through a background
reaction adds latency and a notification and removes the one person who can
answer.

The second reason is the one already recorded on #377 for metadata generation:
an automated writer or gate that fires unattended on a state transition removes
the human from the loop on exactly the content where the human matters most.

So: a live advisory in the editor, plus an opt-in hard gate at publish for
operators who want a claim to be un-shippable rather than merely flagged.

## Rules

A rule is a map:

```elixir
%{code: :regulatory_claim, severity: :error, phrases: ["fda approved"]}
```

Phrases match **case-insensitively, on whole-word boundaries**, and tolerate
runs of ordinary whitespace between words, line breaks included — so
`clinically proven` still matches text the editor wrapped across a line. (Like
`Kiln.Advisory.Body`'s own folding, "whitespace" here is `\s`, which does not
include a non-breaking space.)

Word boundaries are not a nicety. As a substring, `cures` matches *manicures*,
*procures* and *secures*. A compliance panel that flags the word "secures" on a
page about data security is one an author switches off within a day, at which
point it catches nothing at all.

### The shipped pack is deliberately narrow

`KilnCMS.Compliance.default_rules/0` ships only phrases that are a claim in
*essentially any context*:

| Code | Severity | What it catches |
|---|---|---|
| `regulatory_claim` | `:error` | Asserted approval or endorsement — "FDA approved", "clinically proven", "doctor recommended" |
| `safety_claim` | `:error` | Unqualified safety — "no side effects", "100% safe", "risk-free" |
| `efficacy_claim` | `:warning` | Guaranteed outcomes — "guaranteed results", "never fails", "miracle cure" |
| `medical_advice_claim` | `:warning` | Positioning the content as a substitute for care — "no need to see a doctor" |

What it pointedly does **not** ship is curative vocabulary — bare "cures",
"heals", "treats". Those are the phrases a health CMS most obviously wants, and
they are also the ones with the most legitimate uses: "this herb cures
nothing", "traditionally used to treat insomnia", an article *about* cure
claims. Where that editorial line falls is a question about a specific
publication's voice and jurisdiction. Shipping a guess would mean every install
starts by switching the panel off.

Add your own — the pack is a starting point, not a standard:

```elixir
config :kiln_cms, KilnCMS.Compliance,
  enabled: true,
  rules:
    KilnCMS.Compliance.default_rules() ++
      [%{code: :curative_claim, severity: :error, phrases: ["cures", "heals", "cure for"]}]
```

A rule code the web layer has no sentence for still renders: the panel quotes
the matched phrases and names the rule. Malformed rules — a bad severity, no
usable phrases — are dropped rather than raising.

A **site's** own phrases (the ones typed into `/editor/compliance`) become one
rule, `:site_claim`, carrying the severity chosen beside them. One fixed code
rather than one per phrase because a code is an atom the web layer translates,
and minting atoms from column values is how a settings table becomes an
unbounded atom table.

### Severity is the operator's statement of meaning

`:error` is what the publish gate acts on, and it is the only severity that
does. `:warning` and `:info` stay advice however the gate is configured. Of the
shipped pack only the regulatory and safety rules are errors, because those are
the two whose failure mode is a reader harmed or a regulator's line crossed
rather than loose marketing copy.

## Negation is not handled, on purpose

"We do not claim it is clinically proven" matches `clinically proven`, and this
reports it.

A negation window — *skip a match preceded by "not" within three words* — would
suppress that one, and would just as readily suppress "not only clinically
proven, but…", which is a claim. Between a false positive an author dismisses
in a second and a false negative that ships an unreviewed claim, a compliance
tool should choose the first.

The panel's job is to say *look at this*, not to render a verdict. That is also
why the shipped severities lean on `:warning`, why the copy is written to be
dismissable, and why the gate is opt-in.

## The default pack is English

`KilnCMS.Compliance.Checks.Claims` reports `:n_a` on a non-English document
under the shipped pack rather than passing it — a document nobody checked is
not a document that is clean, and green would be the single most misleading
thing this could show.

Any **other** rule set runs in every locale — whether the phrases came from an
operator's config or from a site's own list. Someone who wrote French phrases
meant them to fire. The test is on the resolved rules, not on a config key: a
site that added one phrase of its own is no longer under the shipped pack alone.

## The disclaimer check

Set on `/editor/compliance`, or deployment-wide:

```elixir
config :kiln_cms, KilnCMS.Compliance,
  enabled: true,
  disclaimer: "This information is not medical advice."
```

`KilnCMS.Compliance.Checks.Disclaimer` warns when the body doesn't contain that
text. Matched as a substring against the folded body — lowercased, whitespace
collapsed — so a disclaimer the editor line-wrapped or an author title-cased
still counts. What it will not survive is rewording, which is correct: text an
operator pinned in config is text they want verbatim.

An empty body is `:n_a`, so a brand-new draft doesn't open with a compliance
error before anything has been written.

## The publish gate

Turned on per site (or, underneath, deployment-wide):

```elixir
config :kiln_cms, KilnCMS.Compliance,
  enabled: true,
  require_at_publish: true
```

`KilnCMS.CMS.Validations.ComplianceClaims` refuses `:publish` and
`:publish_scheduled` when the document carries an `:error`-severity phrase, and
names every offending phrase at once rather than making an author rediscover
the next one on each retry. A scheduled publish is gated identically — a claim
that must not go live by hand must not go live by scheduler.

Details worth knowing before switching it on:

**It resolves the settings of the site being published to, uncached.** The gate
runs inside the write transaction, and a cached resolve there would check out a
second pool connection while holding the first — see
`KilnCMS.Compliance.Settings.for_org_uncached/1`. One indexed single-row read
per publish is nothing; it is the editor's per-keystroke path that needs the
cache, and that one is not in a transaction.

**It scans the SEO fields too, each on its own.** The title, SEO title and SEO
description are scanned alongside the block text. A claim in the meta
description is the one that ships to a search results page, where more people
read it than read the article.

Each field is scanned separately and the results merged — never concatenated.
Joining them first invents claims that are not in the document: a body ending
"use the sauna at your own risk" followed by a title "Free consultation guide"
produces `risk free` across the seam, and the author is refused for words that
never appear together anywhere they can see. The editor scans in separate
pieces for the same reason.

**It applies the panel's locale test.** Under the shipped English pack a
non-English document is skipped, exactly as `Checks.Claims` reports `:n_a` for
it. Otherwise a French page would render no panel at all and then be refused at
publish quoting an English phrase nobody was shown — which is the one
divergence between gate and panel this feature must not have.

**It only gates what an edit introduces.** Editing an already-published page
re-fires its artifacts, so the gate also runs on `:update` for a live record —
otherwise adding a claim to a published page would ship it without ever passing
`:publish`. Restoring a version does too, via `KilnCMS.CMS.Changes.RestoreVersion`:
that action force-changes fields in a `before_action`, so a plain validation
never sees them, and it is re-run by hand there.

All three are scoped to claims *this write introduces* (`only_new`), diffed per
phrase. Without that, switching `require_at_publish` on would make every
already-live page carrying a flagged phrase un-editable: an author fixing a
typo refused until they also rewrote a sentence they never touched. Drafts are
never gated — a draft in progress is not an assertion that it is done.

This mirrors `KilnCMS.CMS.Validations.MediaAltText`, which solves the same
problem for alt text and has the same three entry points.

**It costs a scan on every write to a live record.** Unlike the alt-text gate,
which is guarded by `changing(:blocks)`, this one also reads the title and SEO
fields, and Ash's `where:` is an AND — there is no "any of these four changed"
to express. So an `:update` on a published record walks the block tree and
scans, even for a metadata-only PATCH. It diffs to zero new offenders and
passes, but it is not free. The gate is opt-in, so this is a cost an operator
asked for; it is the reason not to switch it on speculatively.

## The in-review badge (#856)

The panel is in the editor; approving someone else's submission happens from
the content list at `/editor?status=in_review`. Before this, an admin with
`require_at_publish` on got the gate's refusal with no panel, no link, and no
way to see the finding without opening the editor — the person doing the
compliance review was exactly the person the feature didn't reach.

`/editor?status=in_review` now shows a grade badge (Good / Needs work / Poor)
on each row, linking into that document's editor. It is:

- **Scoped to `in_review` only.** The other status filters don't render it —
  seeing a claim on a *draft* is the author's business in the editor, not the
  list's.
- **Off with the feature, and per document locale.** `nil` (no badge) when
  compliance is off for the org, or when the document's locale isn't one the
  shipped English pack can judge — the same `:n_a` posture `Checks.Claims`
  takes. A document nobody scanned must not render as clean.
- **Scanned the same way the gate is** — body text, title, SEO title, SEO
  description, each field separately and merged, never concatenated (the same
  reasoning the publish gate section above gives) — so a phrase this badge
  shows and one the gate would refuse are always the same phrase.
- **Read from the denormalized `search_text` column, not `blocks`.** The gate
  itself re-derives body text from the block tree because it runs inside the
  write it is judging; the badge is informational and reads the same
  plain-text projection full-text search already uses, so a 50-row page costs
  a handful of cheap regex passes over short columns rather than casting the
  block tree for every row.
- **Not the gate.** `require_at_publish` still decides whether a claim blocks
  going live; this is visibility into what that gate will say, so the person
  who can act on it sees it before clicking Approve instead of after.

## Performance

Advisory checks re-run on **every keystroke**, so scanning a whole document for
every configured phrase does not happen inside a check. It is split:

- The **body** is scanned when the body changes, alongside the rest of the
  memoized `Kiln.Advisory.Body` work, and handed to the check as a
  `Kiln.Advisory.Context` fact.
- The **scalar fields** (title, SEO title, SEO description) are scanned per
  keystroke — one regex pass over a few hundred bytes.

Each rule compiles to its own alternation and gets its own pass — four passes
with the shipped pack. A single combined alternation would be one pass, and was
the first design, but it has to attribute a match by looking the matched text
back up, and that lookup is wrong in three ways that all fail *silently*: PCRE
case-folding and `String.downcase/1` disagree (so "no ſide effects" matches and
is then dropped); two rules naming the same phrase collapse to one entry, last
writer winning, quietly demoting a shipped `:error` out of the gate; and one
consuming alternation is leftmost-first, so "always works" swallows "works for
everyone" and the overlapping rule is never seen. Per rule, the rule that
matched is the rule that was scanned.

The compiled form is cached under the rule list that produced it, and several
rule sets are kept at once: with per-site vocabularies, a single-entry cache
meant two sites with different phrase lists evicted each other on every scan,
and `:persistent_term.put/2` is not a cheap write — it scans every process on
the node.

The **resolved settings** are cached too, per org, for five minutes, and dropped
precisely by `KilnCMS.CMS.Changes.BustCompliance` on any settings write — so an
admin who turns the gate off to unblock a release does not wait out a TTL.

None of this applies to the **publish gate**, which is a per-write cost rather
than a per-keystroke one — see above.

A caller that computed no scan gets `:n_a`, never `:ok`. That distinction is
the point in a compliance context.

## Where things live

| | |
|---|---|
| `KilnCMS.Compliance` | the rule pack and the scanner |
| `KilnCMS.Compliance.Settings` | the resolved per-site settings: row over config |
| `KilnCMS.CMS.SiteCompliance` | the per-org row |
| `KilnCMSWeb.ComplianceLive` | `/editor/compliance` — the admin page and the explainer |
| `KilnCMS.Compliance.Checks.Claims` | phrases → findings, reading the scan as a fact |
| `KilnCMS.Compliance.Checks.Disclaimer` | required disclaimer present |
| `KilnCMS.CMS.Validations.ComplianceClaims` | the opt-in publish and edit gate |
| `KilnCMS.CMS.Changes.RestoreVersion` | re-runs that gate on a version restore, which bypasses plain validations |
| `KilnCMSWeb.ComplianceComponents` | one code-to-sentence table |
| `KilnCMSWeb.ContentEditorLive` | memoized body scan, per-keystroke field scan, the panel |
| `config/config.exs` | the defaults, and the check registration on `Kiln.Advisory` |

## What this does not do

Claim checking is one of three boxes on #377. The other two — automated
internal linking and metadata generation on a state transition — are tracked
there, and metadata generation shipped in a different (human-in-the-loop) shape
in #541; see [AI assist](ai-assist.md).

Within claim checking itself, the shipped scope is phrase-level. It has no
model of a *sentence's* claim structure, does not distinguish a cited claim
from an uncited one, and does not link a finding to the block it came from —
findings are document-level and quote the phrase instead. Those are worthwhile
and were left out on purpose rather than done badly.

One gap is worth naming because the issue's wording implies it:

**A site's vocabulary is one flat list at one severity.** `/editor/compliance`
writes every phrase a site adds into a single `:site_claim` rule. A publication
wanting *two* house rules at different severities — say a blocking list and an
advisory one — cannot express that without an operator editing config. The
shape is there (the resolver merges rule lists), and the UI is what is narrow;
splitting it is a change to this page, not to the model.

**The governance dashboard is fed** (#858). `/editor/governance` carries a
**Live claims** panel: every published document on the site, scanned against the
site's own vocabulary, showing the phrase that matched and whether it is one the
publish gate would refuse. That is the question a compliance officer has and the
one the editor panel and the publish refusal both cannot answer, since both are
about the document in front of you.

It is **recomputed on read, not stored**. There is no findings table and nothing
is written on publish, which is worth knowing for two reasons. It answers "what
is live now" and cannot answer "what did this page claim in March" — point-in-time
history is next door on the same dashboard if that is the question. And a
finding is always judged by the rules in force *now*, so narrowing a site's
vocabulary retires the finding rather than leaving a record judged by a rule
nobody uses any more. `KilnCMS.Compliance.Report`'s moduledoc carries the full
reasoning, including why not writing on publish sidesteps
`AutoCompleteTasks` force-completing the very task a finding might have opened.

The scan is bounded at `KilnCMS.Compliance.Report.document_cap/0` most recently
updated published documents; past that the panel says so rather than describing
a subset as the whole.

Per-org configuration itself is done: #857 moved the switches, the disclaimer
and the vocabulary onto `KilnCMS.CMS.SiteCompliance` with an admin page, which
is the same shape as outbound [link checking](link-checking.md), branding, code
injection and the form spam keywords.
