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
| `flag_duplicates` | Email near-duplicate findings for the document (#377) | `to` |
| `suggest_tags` | Email semantic tag suggestions for the document (#377) | `to` |

`send_email` subject/body and templates support `{{title}}`, `{{slug}}`,
`{{id}}`, `{{type}}`, `{{event}}` (each HTML-escaped).

**HTTP / Slack notifications** are deliberately *not* an automation action —
that's exactly what the signed, SSRF-safe [Webhooks](webhooks.md) feature does.
Automation complements it with the reactions webhooks can't do.

### Examples

```
When post.published        → send_email  {"to": "editors@site.com", "subject": "Live: {{title}}"}
When *.published           → reindex
When *.updated             → invalidate_cache
When page.unpublished      → broadcast   {"topic": "site:page"}
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

- **Triggers** are the three webhook lifecycle events. `in_review` /
  `returned_to_draft` (review-workflow transitions) don't currently emit through
  the webhook funnel; wiring them in is a natural Phase-2 addition (the executor
  already keys on the event name).
- **One reaction per rule.** Multi-step flows (do A then B) are modeled today as
  several rules on the same trigger; a sequenced multi-action rule is a follow-on.
- **Reaction set** covers email / broadcast / cache / reindex, plus the
  embedding-driven editorial-intelligence reactions (#377): `flag_duplicates`
  and `suggest_tags` pair naturally with the `in_review` trigger as lightweight
  review gates. They are silent when nothing is found, and no-ops when semantic
  search is disabled. The *model-driven* half of #377 (an LLM acting through
  the MCP surface — drafting internal links, generating metadata) deliberately
  lives OUTSIDE the CMS: these reactions and the `KilnCMS.Search.Related`
  seams are what such an agent consumes.
- **Event dedupe:** rule jobs are Oban-unique per {rule, event, document}
  within a minute, so re-fired duplicate events can't double-run side-effectful
  reactions.
- **Config** is entered as JSON; per-action structured form fields are a UI
  refinement.
