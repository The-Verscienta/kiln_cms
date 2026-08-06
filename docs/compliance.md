# Editorial claim checking

The content editor can show a **Compliance** panel: the phrases in a document
that a regulator, a clinic's counsel, or a house style guide would want a second
look at before it goes live. "FDA approved". "No side effects". "Guaranteed
results".

This is the compliance third of #377, and it is built on the same machinery as
the SEO and accessibility panels — see [Editorial advisories](advisories.md).
Everything here is **off by default**.

## Turning it on

```elixir
config :kiln_cms, KilnCMS.Compliance,
  enabled: true,
  require_at_publish: false,
  disclaimer: nil,
  rules: :default
```

| Key | Effect |
|---|---|
| `enabled` | Whether the checks run and the panel appears. Off, both checks report `:n_a` and the panel never renders. |
| `require_at_publish` | Whether an `:error`-severity match **refuses the publish**. Off, everything is advice. **Requires `enabled: true`** — on its own it is inert. |
| `disclaimer` | Text a body must contain verbatim, or `nil`. |
| `rules` | `:default` for the shipped pack, or your own list. |

The two are separate switches on purpose, but they are not independent:
`require_at_publish` is read through `enabled`, so setting it alone does
nothing. Most publications want the panel long before they want a gate, and
turning a claims vocabulary into a hard publish refusal is a decision an
operator should make deliberately.

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

**Custom** rules run in every locale. An operator who configured French phrases
meant them to fire.

## The disclaimer check

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

The compiled form is cached and rebuilt only when the configured rules change.

None of this applies to the **publish gate**, which is a per-write cost rather
than a per-keystroke one — see above.

A caller that computed no scan gets `:n_a`, never `:ok`. That distinction is
the point in a compliance context.

## Where things live

| | |
|---|---|
| `KilnCMS.Compliance` | config, the rule pack, the scanner |
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

Three gaps are worth naming because the issue's wording implies them:

**The approver doesn't see the panel.** #377 says "in the review workflow", and
in this codebase that means `draft → in_review → published` with an **admin**
approving someone else's submission from the content list. The panel is in the
editor; the approver's list has no compliance column. With the gate on, an
admin clicking approve gets the refusal without ever having seen the finding.
Tracked separately.

**Nothing feeds the governance dashboard.** The issue ties box 3 to #352, and
`docs/p3-plan.md` says claim checks feed that dashboard. `/editor/governance`
has no compliance surface. Also tracked separately.

**Configuration is global, not per-org.** Every comparable operator switch here
— outbound [link checking](link-checking.md), branding, code injection, form
spam keywords — is a per-org resource with an admin UI. This is `config.exs`
only, so on a multi-org install one tenant's vocabulary and gate apply to all
of them. That is the gap to close before this is used on a shared instance.
