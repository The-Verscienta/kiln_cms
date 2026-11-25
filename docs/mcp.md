# MCP endpoint — LLM authoring

KilnCMS serves a [Model Context Protocol](https://modelcontextprotocol.io)
(MCP) endpoint at **`/mcp`** so LLM clients (Claude Code, Claude Desktop,
custom agents) can read and **author** content with typed tools instead of
hand-rolled HTTP. It is powered by [`ash_ai`](https://hexdocs.pm/ash_ai): each
tool is an Ash action on the `KilnCMS.CMS` domain, executed as the caller
through the exact same policies as every other surface.

`/mcp` was historically the *only* key-authenticated surface that could write.
As of #330 the JSON:API and GraphQL surfaces are **also write-capable** (the
deliberate reversal of decision D7), using the **same** `:read_write` API-key
scope and resource policies described here — see
[json-api.md](json-api.md) → "Writing" and
[headless-graphql-api.md](headless-graphql-api.md) → "Mutations". `/mcp` remains
the LLM-tailored surface (typed tools, tool-list scoping) and, unlike those two,
exposes **no** publish/unpublish/delete tools at all — LLM authoring stays
draft-only by design.

## Authentication: write-scoped API keys

`/mcp` accepts **API keys only** (`Authorization: Bearer kiln_…`) — no JWT or
anonymous access; anything else, a valid, expired or garbled JWT included, is a
`401`. The scheme is case-insensitive, and the key need not be the first
`Authorization` value (a proxy may add its own); if there is more than one key,
the first decides (`KilnCMSWeb.Plugs.RequireApiKey`, #2632). Mint keys at `/editor/api-keys` (admin-only). A key acts as its owning
user, bounded by its `access` scope. A site's
[two-step sign-in requirement](two-factor-auth.md#requiring-two-step-sign-in-on-a-site)
never applies to a key: it keeps working for an owner the site holds.

| Key `access`  | Owner role | What the LLM can do over `/mcp`                          |
| ------------- | ---------- | -------------------------------------------------------- |
| Read-only     | any        | Read tools only (scoped to the owner's visibility)       |
| Read + write  | `:viewer`  | Reads only — the role has no authoring rights            |
| Read + write  | `:editor`  | Author: create/update drafts, stage edits to live records, tag, submit for review |
| Read + write  | `:admin`   | As editor, plus edit any record its role could           |
| Draft write   | `:viewer` service account | `create_*`; `update_*` of its **own drafts** only. No submit-for-review, no tags or categories, no publishing |

A `draft_write` key (#2273) is for a headless app that submits content, not for
an LLM author: it is refused on everything but creating drafts and editing the
ones it authored, and that bound holds even if its owner is later promoted. The
review, tag and category tools are not even listed for it. See the
[consumer guide](headless-consumer-guide.md#submitting-drafts-from-your-app-the-draft_write-key).
Over `/mcp` the `X-Kiln-On-Behalf-Of` header is not read, so a draft records the
key but no `on_behalf_of` label; use JSON:API or GraphQL when you need one.

**The recommended setup for an LLM author is a read + write key on a dedicated
`:editor` account.** Its work lands as drafts and goes through `in_review`;
publishing stays a human (admin) approval step. Publishing and hard deletes are
**never** exposed as tools, whatever the key or role, and the content policies
additionally forbid destroys for any API-key actor.

Enforcement is layered, all before the admin policy bypass:

1. **Transport** — `/mcp` requires a valid, unexpired, unrevoked key.
2. **Tool listing** — `tools/list` only offers tools the authenticated key may
   actually run, so a read key never even sees `create_page`.
3. **Policies** — every content/taxonomy/media resource forbids create/update
   for read-scoped keys (`KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess`,
   which fails closed) and destroy for all keys, then the owner's role applies
   as usual.

## Tools

Reads (all policy-scoped — drafts are visible only if the owner is an editor):
`read_pages`, `read_posts`, `read_entries`, `read_type_definitions`,
`read_field_definitions`, `read_tags`, `read_tag_groups`, `read_categories`.

> **Custom fields: `custom_filter`, `custom_where`, `custom_sort`.**
> `read_pages`, `read_posts` and `read_entries` take these under `input`.
> They're JSON:API's parameters as JSON, snake_case throughout. The tool's own
> `filter` and `sort` reach built-in columns only: a custom field's name in
> `filter` is a `no such field` error (or, if it matches a built-in column
> such as `title`, filters that column).
>
> ```json
> {"name": "read_posts", "arguments": {"input": {
>   "custom_filter": {"price": {"gt": 10}, "color": "red"},
>   "custom_sort": "-price,_native:title"}}}
> ```
>
> ```json
> {"name": "read_posts", "arguments": {"input": {
>   "custom_where": [
>     {"name": "price", "int": {"gte": 10, "lt": 50}},
>     {"name": "color", "string": {"in": ["red", "green"]}}]}}}
> ```
>
> - `custom_filter` maps field names to a value (equality) or to an object of
>   operators, and takes the `_or`, `_and` and `_not` groups and `_native` (built-in
>   columns). The
>   operators, value shapes, equality matching and private fields are in
>   [json-api.md](json-api.md) → "Custom fields".
> - `custom_where` is a list of typed conditions, `{"name": …, <kind>:
>   {operators}}` with exactly one kind, or a group (`_or` / `_and` of a list of
>   conditions, `_not` of one), nesting 4 deep and 50 conditions in all. See
>   [Typed conditions](json-api.md#typed-conditions-custom_where). Unlike a
>   JSON:API query string, it takes several conditions: at most 10 at the top
>   of the list (a group counts as one), and 50 values in an `in`:
>
>   ```json
>   {"name": "read_posts", "arguments": {"input": {
>     "custom_where": [
>       {"name": "price", "float": {"lt": 50}},
>       {"_or": [
>         {"name": "count", "int": {"eq": 1}},
>         {"_not": {"name": "count", "int": {"eq": 5}}}]}]}}}
>   ```
>
> - `custom_sort` sorts a single-valued reference or media field by its
>   target's current title (filename for media), with targets the key's owner
>   cannot read last; a list of them is refused. See "Sorting" in
>   [json-api.md](json-api.md) → "Custom fields".
> - A bad name, kind, operator or operand comes back with `isError: true` and
>   the API's error text, prefixed by the argument (`custom_where: unknown
>   operator "notEq" …`). Some messages spell operators and kinds the GraphQL
>   way (`notEq`, `isNull`, `dateTime`). Send the snake_case form.

Search: `search_content` (`query`, optional `limit` 1–25 and `locale`) runs the
same hybrid search as `/api/search` and `/api/ask` — keyword, title, alias and
semantic legs fused and ranked, with the site's search synonyms applied
(`/editor/search-synonyms`) — under the key's own read policies, so an
editor's key finds drafts too. It answers one list across every content type,
best first, each hit with its `type`, `id`, `slug`, `score` and `legs`, plus
`also_searched`: the alternate wordings the site's synonyms added.

Authoring (require a write key + editor role): `create_page` / `update_page` /
`save_page_working_copy` / `submit_page_for_review`, the same four for posts
and dynamic-type entries (`create_entry` needs a `type_definition_id` —
discover them with `read_type_definitions`), plus `create_tag` and
`create_category`. `create_tag` takes an optional `tag_group_id` — discover
the groups with `read_tag_groups`.

### Live records

`update_*` edits **drafts** (and records in review or archived). On a
**published** record it is refused, whatever the key's role, with an error
naming `save_*_working_copy`: `update_*` writes the live row, so the edit
would reach readers without anyone reviewing it.

`save_page_working_copy` / `save_post_working_copy` /
`save_entry_working_copy` edit a published record the way the editor does
([The working copy](working-copy.md)). The edit is held in the record's
working copy, readers keep the published version, and the document shows
**Live · draft** until a person clicks **Publish changes** (or discards the
changes). They take:

- `title` and the body as `block_tree` or `body_markdown` (not both) — the
  held text. Leave one out and the copy keeps what it had (the published text
  if there was no copy yet).
- `fields` — the other held settings, keyed as `update_*` takes them: `slug`,
  `path_alias`, `locale`, `excerpt`, the `seo_*` fields, `canonical_url`,
  `noindex`, `nofollow`, `custom_fields`, `category_id`, `featured_image_id`,
  and the tag and related-content ids (`tag_ids`, `add_tag_ids`,
  `remove_tag_ids`, and the same three for each related type). They are
  validated as an `update_*` would validate them. A key left out keeps what
  the copy holds. Any other key, such as the audience, passphrase or
  schedule, is refused with an error naming it: those are not held (they
  apply at once in the editor), so over `/mcp` they can be changed on a draft
  but not on a published record.

The working-copy tools refuse a record that is not published; use `update_*`
for those. A `draft_write` key gets neither the tools nor the action.

### Edit a published page from an MCP client

You need a read + write key on an `:editor` or `:admin` account (see the
table above), and a published page. A person with an editor or admin account
reviews the edit afterwards.

1. **Find the page and its id.** Call `read_pages` filtered on the slug:

   ```json
   {"name": "read_pages", "arguments": {"input": {},
     "filter": {"slug": {"eq": "about"}}}}
   ```

   The result lists the page with its `id`. Its `state` is `published`.

2. **Stage the edit.** Call `save_page_working_copy` with the page's id. Send
   only what changes:

   ```json
   {"name": "save_page_working_copy", "arguments": {"id": "<page id>",
     "input": {
       "title": "About the kitchen",
       "body_markdown": "We cook **seasonal** food.",
       "fields": {"seo_description": "Who we are and what we cook"}}}}
   ```

   The result is not `isError`. Readers still get the published title, body
   and description.

3. **Review and publish it.** In the editor, open the page from the content
   list (it is marked *edited since publishing*) or at
   `/editor/content/page/<page id>`. Its state pill reads **Live · draft**.
   Read the changes, then click **Publish changes**, or choose **Discard the
   changes** from the menu beside it. *Publish changes* needs an editor or
   admin account; it is not a tool, so the model cannot do this step.

Posts and entries work the same way with `read_posts` /
`save_post_working_copy` and `read_entries` / `save_entry_working_copy`.

What can go wrong:

- **`update_page` on the published page** answers `isError: true` with
  `this record is published, and MCP edits never go live directly; use the
  save_*_working_copy tool to stage the change for a person to publish`.
  Nothing is written. Use `save_page_working_copy`.
- **`save_page_working_copy` on a page that is not published** (a draft, a
  page in review, an archived one) answers `isError: true` and holds
  nothing. Use `update_page`.
- **Both `block_tree` and `body_markdown`** in one call is refused.
- **A key in `fields` that the copy doesn't hold** is refused with
  `holds only content fields; save <keys> through :update`.
- **A malformed Portable Text body in `block_tree`** is refused with its path,
  as on `update_*` (see *Body* below).
- **The tool isn't listed** for a read-only key, a `draft_write` key, or a
  write key on a `:viewer` account. On a project that overrides
  `:mcp_tools`, check the three names are in the list (see the end of this
  section).

This rule is MCP's. JSON:API `PATCH`, GraphQL and in-context editing still
edit a live record directly through `:update`, on purpose
([The working copy](working-copy.md#not-in-this-change)). A **content link**
on a published source also shows at once (see *Links* below).

Links: `read_content_links`, `create_content_link` and `update_content_link`
read and write payload links between any two records, the same links
`/api/json/content-links` writes ([json-api.md](json-api.md)). A link has a
`kind` naming the relation and an optional `position`, `label` and
`metadata`. Writing one is authorized as an edit of its **source** record, so
an editor key may link from anything it may update. Filter
`read_content_links` on `source_id` to see what a record already links to
before adding more. A link is not part of its source's document, so one on a
published record shows at once, with no version and no review. Three limits:

- `kind: reference` is refused. Those edges mirror a reference custom field;
  write the field instead.
- `kind` takes a name the server already knows (`related`, the default, and
  the kinds Kiln uses); an unknown name is refused rather than created, as on
  JSON:API ([json-api.md](json-api.md)). The tool's own description suggests
  `see_also`, which a server does not know unless something in it uses that
  kind.
- There is no delete tool, as for every other resource here. A link created
  in error is removed by a person, not by the model.

A read key is offered `read_content_links` only; the two write tools are
listed for a write key whose owner is an editor or admin of the site, so a
viewer's write key and a `draft_write` key can't write links. A key whose
owner is an editor or admin reads every link on the site; any other key reads
a link only when it may read both of its ends. `update_content_link` changes
`position`, `label` and `metadata`: a link's ends and its `kind` are fixed,
so to point somewhere else, create a new link.

To link a post to background reading, check what it already links to, add
the link, then relabel it:

```json
{"name": "read_content_links", "arguments": {
  "filter": {"field": "source_id", "operator": "eq", "value": "<post id>"}}}
```

```json
{"name": "create_content_link", "arguments": {"input": {
  "source_id": "<post id>", "target_id": "<other record id>",
  "kind": "related", "position": 2, "label": "Background"}}}
```

The created link comes back as the tool result's text, a JSON object with
its `id`. Pass that id to change the link:

```json
{"name": "update_content_link", "arguments": {"id": "<link id>",
  "input": {"label": "Further reading", "position": 0}}}
```

A `kind: reference` link comes back with `isError: true`, and nothing is
written.

> **Custom fields on a write.** `create_*` and `update_*` take
> `custom_fields` under `input`, checked as a JSON:API write is
> ([json-api.md](json-api.md) → "A single custom field takes one value").
> A refused value comes back as a tool result with `isError: true` (HTTP
> `200`) naming the field, and nothing is written:
>
> ```json
> {"name": "update_page", "arguments": {"id": "<page id>",
>   "input": {"custom_fields": {"subtitle": {"en": "x"}}}}}
> ```
>
> answers `isError: true` with `Subtitle (subtitle) must be a single value,
> not an object or a list`. A reference field that accepts only some records
> ([Limit what can be picked](extending-content.md#limit-what-can-be-picked))
> refuses another the same way: `“Title” isn't one of the records this field
> accepts.` The tools never create a record from a title; create it first
> (`create_page`, …), then connect its id.

> **Change severity: `change_severity`.** `update_page` / `update_post` /
> `update_entry` accept an optional `change_severity` (`critical`, `notable` or
> `routine`), but it is recorded only on an edit of a **published** document,
> and over MCP those are refused ([Live records](#live-records)). An edit
> staged with `save_*_working_copy` gets its severity when a person clicks
> **Publish changes**. See
> [json-api.md](json-api.md#change-severity-how-much-an-edit-matters).

> **Change note: `change_note`.** The same update tools accept an optional
> `change_note`, a short plain-text reason stored on the edit's version and
> shown in the editor's History. Never required over MCP, even on a type whose
> editor asks for one. See
> [json-api.md](json-api.md#change-note-why-an-edit-was-made).

> **Body: `body_markdown`.** The create/update tools take the body either as
> `block_tree` (typed block maps) or as `body_markdown` — plain Markdown, the
> shape a model usually has already, converted server-side into the same
> blocks (see [Markdown](markdown.md#writing-markdown-through-the-api)). One or
> the other, not both; raw HTML in the Markdown is sanitized. Portable Text in a
> `block_tree` is checked as JSON:API checks it
> ([json-api.md](json-api.md#block-tree-portable-text-check)): a
> refused body is a tool error (`isError: true`) naming the path, and nothing is
> written.

> **Tags: prefer `add_tag_ids` / `remove_tag_ids`.** `update_page` /
> `update_post` / `update_entry` accept three tag arguments (#521):
>
> | Argument | Semantics |
> |---|---|
> | `add_tag_ids` | Attaches the listed tags, leaves the rest attached. Re-adding an already-attached tag is a no-op; an unknown id is an error. |
> | `remove_tag_ids` | Detaches the listed tags, leaves the rest attached. Removing a tag that isn't attached is a no-op. |
> | `tag_ids` | **Replaces** the whole set — sending one id detaches every other tag. Only use it to set the complete list, and read the current tags first. |
>
> `tag_ids` cannot be combined with either merge verb in one call, and the same
> id cannot appear in both `add_tag_ids` and `remove_tag_ids`; either is
> rejected rather than silently resolved. A repeated id inside one list is
> de-duplicated rather than rejected.
>
> The merge verbs are **update-only**. `create_page` / `create_post` /
> `create_entry` have no existing tags to merge against and take `tag_ids`
> alone; sending `add_tag_ids` to a create is an error.
>
> One asymmetry to plan around: `add_tag_ids` fails loudly on an id that
> matches no tag, but `remove_tag_ids` swallows it, so removal stays idempotent
> on a retry. A successful `update_*` is therefore not evidence a removal
> matched anything.
>
> **Check the result rather than the status.** `update_page` / `update_post` /
> `update_entry` load the record's `tags` and `category` into their response
> (#640), so a removal that matched nothing leaves the tag listed in the payload
> you already have. No follow-up `read_tags` needed.
>
> This covers tags and category only. `create_*` does not load them and does not
> need to: `tag_ids` on a create hard-errors on an unknown id, and `category_id`
> is echoed back as an attribute.
>
> **The related-content links carry the same verbs (#637).** Alongside
> `related_post_ids` (which replaces), `update_post` takes `add_related_post_ids`
> / `remove_related_post_ids`, and the sibling `add_related_page_ids` /
> `remove_related_page_ids` (and `…_related_entry_ids` on `update_entry`). The
> rules are identical — prefer the merge verbs for a partial update, don't
> combine a complete-set argument with its verbs, and don't list one id in both.
>
> They come back too, as `related_links` — but **only when the call named one
> of those arguments** (#996). A write that never mentions related links does
> not carry them, because a document may have many and most writes do not touch
> them.
>
> `related_links` is a projection: `[{"id": …, "title": …, "slug": …}]`, not the
> related records. That is deliberate — loading the relationship would put whole
> related posts, bodies included, into every write response, since `load` cannot
> project.

> **No media upload tool, on purpose.** Every other authoring tool produces
> a draft that a human approves before anyone sees it. Media has no draft
> state: an uploaded file is live at its public URL the moment it lands, and
> the upload pipeline has no review step to route it through. An
> `upload_media` tool would therefore be the one tool whose output an LLM —
> or a prompt injected into what it is reading — could publish on your
> domain by itself. Agents that need an image can reference one by URL in a
> draft for the reviewer to import, or an integration can call the REST
> upload API (`POST /api/media`, [api.md](api.md#uploading-media)) with its
> own key, where the file is the integration's deliberate act rather than a
> model's.

The tool set lives in the `tools` block on `KilnCMS.CMS` and the
`config :kiln_cms, :mcp_tools` list in `config/config.exs` (read at compile
time by the `/mcp` forward in `KilnCMSWeb.Router`) — add a tool in both places.

A downstream project can expose MCP tools for its own content types without
touching the core: add a `tools` block (via the `AshAi` extension) to your
content domain, then override `:mcp_tools` in your project config. As with
`ash_domains`, the override replaces the list — restate the core tools and
append your own. An override written before 1.12 lacks `read_content_links`,
`create_content_link` and `update_content_link`, so `/mcp` doesn't serve them
until you add the three names. One written before the working-copy tools lacks
`save_page_working_copy`, `save_post_working_copy` and
`save_entry_working_copy`: without them a model can't edit a published record
over `/mcp` at all, since `update_*` refuses one.

## Connecting a client

Claude Code:

```bash
claude mcp add --transport http kiln https://your-kiln-host/mcp \
  --header "Authorization: Bearer $KILN_API_KEY"
```

Or in a `.mcp.json` / Claude Desktop config:

```json
{
  "mcpServers": {
    "kiln": {
      "type": "http",
      "url": "https://your-kiln-host/mcp",
      "headers": { "Authorization": "Bearer kiln_…" }
    }
  }
}
```

Smoke-test with curl (JSON-RPC over HTTP):

```bash
curl -s https://your-kiln-host/mcp \
  -H "authorization: Bearer $KILN_API_KEY" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## Operational notes

- Requests ride the `:api` rate-limit bucket.
- A key reads as its owner. A private custom field that the owner's role hides
  from them ([granular-rbac.md](granular-rbac.md#per-custom-field-grants-and-read-restrictions))
  is left out of reads and of create/update results, and a write that changes a
  custom field outside the owner's field grant is refused.
- Keys expire and can be revoked instantly at `/editor/api-keys`; a revoked
  key 401s on the next request.
- A key minted by a newer Kiln release with a scope this release doesn't know
  401s too, for example after a rollback; mint the client a new key
  ([API keys](api.md#api-keys-third-party-access)).
- Every write is attributed to the key's owning user in versions/audit trails —
  another reason to give each LLM integration its own account.
