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

`send_email` subject/body and templates support `{{title}}`, `{{slug}}`,
`{{id}}`, `{{type}}`, `{{event}}` (each HTML-escaped).

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
- **The LLM budget is shared with the editor panel**, per org
  (`KilnCMS.Seo` `per_org_limit`, default 200/hour). A `suggest_metadata` rule
  gets its own per-rule ceiling on top (`per_user_limit`, default 20/minute) so
  one runaway rule can't starve the others — but a hot rule can still consume
  the org allowance an editor's "Suggest with AI" button draws on. Scope rules
  to `in_review` rather than `updated`, and raise `per_org_limit` if you mean
  to run them broadly.
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
  (`KilnCMS.CMS.ContentSerializer`), so templates and broadcasts have the title,
  slug, id, state, etc.

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
- **Config** is entered as JSON; per-action structured form fields are a UI
  refinement.
