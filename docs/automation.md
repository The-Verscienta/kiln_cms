# Editorial automation (a Directus Flows answer)

A no-code **"when X happens, do Y"** layer for editorial workflows
([#342](https://github.com/The-Verscienta/kiln_cms/issues/342)) — Kiln's answer
to Directus Flows, without an embedded scripting runtime. It's pure Elixir over
the primitives Kiln already runs in production: the content **state machine**
(the triggers), **Oban** (the executor), and **PubSub / MTA / cache** (the
reactions).

## The asymmetry

Automation platforms bolt on a JavaScript/visual scripting engine. Kiln doesn't
need one: publishing already emits editorial events (the same funnel the webhook
system uses), Oban already runs isolated, retried background jobs, and the MTA /
PubSub / cache are already wired. Automation is a thin, admin-managed rule model
on top.

## Using it

Manage rules at **`/editor/automation`** (admin-only). A rule is:

- **When** — a lifecycle trigger: `published`, `unpublished`, or `updated`.
- **Content type** — a specific type (`post`, a dynamic type's name) or *any*.
- **Do** — one reaction (below), configured with a small JSON `config`.

### Reactions

| Action | What it does | `config` |
| --- | --- | --- |
| `send_email` | Deliver an email via the MTA | `to`, `subject`, `body` (templated) |
| `broadcast` | `Phoenix.PubSub` broadcast `{:automation_event, event, payload}` | `topic` (default `"automation"`) |
| `invalidate_cache` | Bust the record's content cache (+ sitemap/llms) | — |
| `reindex` | Re-fire the record (refreshes artifacts + search indexes) | — |
| `newsletter` | Send the published document to subscribers (#376) | `segment_id` (omit = all confirmed), `subject` (defaults to the title) |
| `flag_duplicates` | Email near-duplicate findings for the document (#377) | `to` |
| `suggest_tags` | Email semantic tag suggestions for the document (#377) | `to` |
| `suggest_links` | Email internal-link suggestions for the document (#377) | `to` |
| `suggest_metadata` | Email proposed `seo_title` / `seo_description` / `seo_keywords` (#377) | `to`, `allow_egress` |
| `social_post` | Announce the publish on Bluesky / Mastodon (#497) — see [social-posting.md](social-posting.md) | `provider` (required), `template` |

`send_email` subject/body and templates support `{{title}}`, `{{slug}}`,
`{{id}}`, `{{type}}`, `{{event}}` (each HTML-escaped).

### `social_post` is the one reaction that cannot be undone

Every other reaction writes somewhere the operator controls — an inbox, a cache,
an index. `social_post` writes to a public timeline in front of an audience, and
a duplicate cannot be taken back.

So it is the one reaction that is **at most once** rather than at least once: it
claims a ledger row before it posts, never retries an ambiguous outcome, and
runs with Oban retries off. The cost is that a genuinely lost announcement stays
lost until someone looks at `/editor/social`. See
[social-posting.md](social-posting.md).

### The intelligence reactions suggest, and never write

The last four rows compute something about the document and **email the
findings**. None of them touches the record, and that is a design decision
rather than an unfinished one.

Generated metadata lands in `<meta>` tags on the public site, so a successful
prompt injection through a document body buys SEO cloaking on your own domain.
Human-in-the-loop is the *primary* control against that; the output constraints
in `KilnCMS.Seo.Draft` (no newlines, no HTML, no URLs, hard truncation) are only
the second layer. A reaction that wrote `seo_description` unattended on a state
transition would delete the primary control.

So automation makes the **computation** unattended — nobody has to remember to
open the panel and ask — while accepting a value stays a click in the editor,
where a human sees it before the public does.

Two consequences worth knowing:

- **They don't retry** — including when the *email* fails. An unconfigured
  generator, an exhausted budget bucket, a provider outage or a greylisting
  relay is logged and dropped. Retrying a nice-to-have suggestion five times
  per document spends real tokens to tell an editor something they can ask for
  directly, and an Oban retry re-runs the generation, not just the send.
- **The SEO draft budget is shared with the editor panel, but people keep a
  reserve.** The org ceiling is `KilnCMS.Seo` `per_org_limit` (default
  200/hour) and every caller draws on it. A `suggest_metadata` rule is keyed
  into its own per-rule bucket on top, so one runaway rule can't starve the
  others — note that bucket's *size* is the same `per_user_limit` that sizes
  every editor's, so there is no separate knob for how fast one rule may run.

  Because it runs unattended, it also stops once the org has spent
  `unattended_share` of the window (default `0.5`), counting **every** caller's
  spend. At the defaults an editor clicking "Suggest with AI" always has at
  least 100 of the 200 available. Without that, a busy day on a
  `*.updated → suggest_metadata` rule ended with every editor getting a
  rate-limit error caused by a rule they can't see and — since this page is
  admin-only — can't inspect.

  Reading the shared counter is deliberate: automation's room shrinks as
  editors work, and a rule can be refused having spent nothing itself. That is
  the priority order this is for. Set `unattended_share: 0.0` to keep
  automation off this budget entirely, or `1.0` for the old shared-bucket
  behaviour. Scope rules to `in_review` rather than `updated`, and raise
  `per_org_limit` if you mean to run them broadly.

  **This covers the SEO draft budget only.** `flag_duplicates` and
  `suggest_tags` have their own bucket — see below.
- **`flag_duplicates` and `suggest_tags` spend a separate embedding budget**
  (#1076). Both reach `KilnCMS.Search.Related`, which computes an embedding per
  block for a document that has none stored, and `suggest_tags` additionally
  embeds every taxonomy tag whose name has no **stored** vector yet — once per
  tag, not per call, since #1085 persists it in `tag_embeddings`. That is
  `config :kiln_cms, KilnCMS.Search` `embedding_per_user_limit` (default
  60/minute) / `embedding_per_org_limit` (default 600/hour) — higher than the
  SEO draft budget because a single local embedding is far cheaper than an LLM
  completion, and `suggest_tags` can spend one unit per untagged taxonomy tag
  in a single call. `embedding_unattended_share` (default `0.5`) is the same
  #943 reserve as `unattended_share` above, so a rule can't leave an editor's
  own "duplicates & tags" panel rate-limited by something it can't see. A rule
  scoped to `in_review` is exactly the case that computes rather than reads —
  a bulk move to that state now stops spending embeddings once the reserve is
  hit, instead of running unbounded.
- **`suggest_metadata` needs `"allow_egress": true`** when the configured model
  provider is off-site (`KilnCMS.Seo.egress?/0`). The editor panel is one
  person deciding to spend one request; a rule is every matching document,
  forever, with nobody watching — a different posture than the one an operator
  agreed to when they pointed the *panel* at a third-party provider. Opting in
  per rule keeps a later provider switch from silently turning the publish
  pipeline into an outbound feed. On-prem (`ollama`/`vllm` on a loopback or
  private endpoint) needs no opt-in, because nothing leaves.

`suggest_links` needs no such flag: both its legs are local — pgvector over
content this deployment already indexed, falling back to Postgres full-text —
so it works on a default install with semantic search off. It emits paths to
paste, not insertions; see `KilnCMS.Seo.Links` for why server-side insertion
into the block tree is ruled out.

**HTTP / Slack notifications** are deliberately *not* an automation action —
that's exactly what the signed, SSRF-safe [Webhooks](webhooks.md) feature does.
Automation complements it with the reactions webhooks can't do.

### Examples

```
When post.published        → send_email  {"to": "editors@site.com", "subject": "Live: {{title}}"}
When *.published           → reindex
When *.updated             → invalidate_cache
When page.unpublished      → broadcast   {"topic": "site:page"}
When post.in_review        → suggest_links     {"to": "editors@site.com"}
When post.in_review        → suggest_metadata  {"to": "editors@site.com"}
```

## How it works

- **Trigger.** Every editorial event funnels through `KilnCMS.Webhooks.dispatch/2`
  (`<type>.published` / `.unpublished` / `.updated`). It calls
  `KilnCMS.Automation.handle_event/2`, which finds the enabled rules that match
  and enqueues one `KilnCMS.Automation.RuleWorker` per rule. `handle_event/2`
  never raises — a rule problem can't break the publish that triggered it.
- **Execute.** Each `RuleWorker` job loads its rule and performs the reaction,
  off-request, isolated, and retried by Oban. A slow email or a failing reaction
  affects neither the content action nor the other rules.
- **Payload.** Reactions receive the same serialized content map webhooks get
  (`KilnCMS.CMS.ContentSerializer`), so it has the title, slug, id, state,
  `audience`, `locked` and the block tree. Note the asymmetry: a **broadcast**
  forwards that whole map, so a PubSub consumer can check `audience`/`locked`
  the way a webhook subscriber does (#1014) — but the email and webhook
  reactions render from a fixed variable whitelist (`title`, `slug`, `id`,
  `type`, `event`), and rule matching is trigger + content type only. There is
  no condition surface on which to say "only public documents", so a rule that
  forwards content outward forwards gated content too.

Modules: `KilnCMS.Automation` (domain + executor), `KilnCMS.Automation.Rule`
(the admin-managed resource), `KilnCMS.Automation.RuleWorker` (the reactions),
`KilnCMSWeb.AutomationLive` (the no-code builder).

## Scope & follow-ons

Phase-1 slice:

- **Triggers** are the webhook lifecycle events: `published` / `unpublished` /
  `updated`, plus the review-workflow transitions `in_review` /
  `returned_to_draft` (#375) — `submit_for_review` and `return_to_draft` emit
  `<type>.in_review` / `<type>.returned_to_draft` through the same webhook
  funnel, so both rules ("on `in_review` → notify") and webhook subscriptions
  can react to them.
- **One reaction per rule.** Multi-step flows (do A then B) are modeled today as
  several rules on the same trigger; a sequenced multi-action rule is a follow-on.
- **Reaction set** covers email / broadcast / cache / reindex / newsletter
  (#376 — "on `published` → send to segment X", deduped per {rule, content,
  publish revision} on the campaign ledger, so re-fires never double-send),
  plus the editorial-intelligence reactions (#377): `flag_duplicates`,
  `suggest_tags`, `suggest_links` and `suggest_metadata` pair naturally with
  the `in_review` trigger as lightweight review gates — silent when nothing is
  found, and inert rather than broken when the capability they need
  (semantic search, a configured generator) isn't there. All four suggest and
  never write; see above for why that boundary is the point rather than a
  limitation.

  What remains outside the CMS is an LLM acting *through the MCP surface* with
  tools it can call. These reactions take strings and return strings, and the
  `KilnCMS.Search.Related` / `KilnCMS.Seo.Links` seams are what such an agent
  would consume.
- **Pending-duplicate dedupe:** a re-fired duplicate event collapses onto the
  still-queued job for the same {rule, event, document}; an event arriving
  while the first job runs or retries is never dropped.
- **Config** is entered as JSON, and **validated against the selected action at
  save time** (`KilnCMS.Automation.Validations.ActionConfig`). A required key
  that is missing, a value of the wrong type, and a key the action does not
  recognize are all refused beside the field rather than accepted and warned
  about at runtime — a rule that cannot work should not be able to sit in the
  list looking enabled. `ActionConfig.shapes/0` is the single description of
  what each reaction accepts, and the admin form renders its per-action key
  hint by reading that table — so the hint beside the field cannot drift from
  what the save will allow.

  Two mistakes it exists to catch: `"allow_egress": "true"` (the string — every
  other key in that textarea is one, and the runtime gate correctly fails
  closed on it), and a missing `to` on `send_email` or on any of the four
  intelligence reactions, all of which deliver by email and nothing else.

  Rules written before this validation existed are not re-checked, and
  AshAdmin writes the attribute directly, so the executor keeps its own
  guards. Per-action structured form fields are still a UI refinement.
