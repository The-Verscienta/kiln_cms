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
anonymous access; anything else is a `401`. Mint keys at `/editor/api-keys`
(admin-only). A key acts as its owning user, bounded by its `access` scope:

| Key `access`  | Owner role | What the LLM can do over `/mcp`                          |
| ------------- | ---------- | -------------------------------------------------------- |
| Read-only     | any        | Read tools only (scoped to the owner's visibility)       |
| Read + write  | `:viewer`  | Reads only — the role has no authoring rights            |
| Read + write  | `:editor`  | Author: create/update drafts, tag, submit for review     |
| Read + write  | `:admin`   | As editor, plus edit any record its role could           |

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
`read_field_definitions`, `read_tags`, `read_categories`.

Authoring (require a write key + editor role): `create_page` / `update_page` /
`submit_page_for_review`, the same trio for posts and dynamic-type entries
(`create_entry` needs a `type_definition_id` — discover them with
`read_type_definitions`), plus `create_tag` and `create_category`.

The tool set lives in the `tools` block on `KilnCMS.CMS` and the
`config :kiln_cms, :mcp_tools` list in `config/config.exs` (read at compile
time by the `/mcp` forward in `KilnCMSWeb.Router`) — add a tool in both places.

A downstream project can expose MCP tools for its own content types without
touching the core: add a `tools` block (via the `AshAi` extension) to your
content domain, then override `:mcp_tools` in your project config. As with
`ash_domains`, the override replaces the list — restate the core tools and
append your own.

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
- Keys expire and can be revoked instantly at `/editor/api-keys`; a revoked
  key 401s on the next request.
- Every write is attributed to the key's owning user in versions/audit trails —
  another reason to give each LLM integration its own account.
