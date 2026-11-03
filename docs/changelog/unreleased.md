# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

<a id="search-synonyms"></a>

- **Search synonyms and aliases, per site (proposal A7).** A site whose
  readers search for "reishi" when its content says "Ling Zhi" had to fix it
  in the consumer: Verscienta's own synonym table was worth +0.058 MRR over
  the backend, and Kiln's own surfaces — `/api/ask`, the editor palette, the
  public `/search` page — got none of it. `KilnCMS.CMS.SearchSynonym` holds the
  rules: a `group` of equivalent terms (`reishi ⇄ ling zhi ⇄ ganoderma`) or a
  `one_way` rule (`tcm → traditional chinese medicine`), multi-word terms
  matched as phrases at word boundaries. `Search.hybrid/3` reads them
  (`KilnCMS.Search.Synonyms`, cached per site and busted on every write) and
  runs each alternate wording of the query through the keyword, title and
  alias legs at half the weight of the same leg on the user's own words — the
  new `synonym` leg — so a record the reader named outranks one a rule named
  for them. The semantic legs do not re-run: the query's one embedding already
  carries its meaning. `global/2` reads the rules once per sweep, and
  `/api/search` reports the alternates it searched as `also_searched`. Editors
  manage rules at `/editor/search-synonyms` (with a "try a query" box); only an
  admin deletes one. A rule write purges the site's CDN key, since it changes
  what a publicly cached `/api/search` URL answers. `/mcp` gains a
  `search_content` tool (`KilnCMS.CMS.ContentSearch`) — the ranked hybrid
  search under the key's own read policies, which MCP clients had no way to
  reach before. The index-time half of the proposal ("index this field's
  values as names") already exists as `names_record` on a field definition
  (`KilnCMS.CMS.NameFields`); a synonym's alternate runs the alias leg too, so
  the two compose.
