# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Changed

<a id="custom-fields-under-the-blocks"></a>

- **Custom fields sit in the editor's main column, under the blocks, instead
  of behind the inspector's Settings tab.** The inspector opens on Preview, so
  a type's own fields (a recipe's chef, an event's venue) were invisible until
  a writer thought to open Settings, where they were mixed in with URL, SEO and
  scheduling. They are now a *Custom fields* panel below the block canvas, the
  way WordPress puts meta boxes under the post body. The panel flags its own
  validation errors, so the Settings tab's alert dot no longer counts them.
  The panel stays visible in the Markdown view. Inputs, names and the save
  path are unchanged. See `KilnCMSWeb.ContentEditor.CustomFieldsPanel`.

<a id="newsletter-pages-in-site-chrome"></a>

- **The newsletter's sign-up and unsubscribe pages render in the site's own
  layout instead of as bare unstyled pages.** "Almost there", "Check that
  address", "Something went wrong" and both unsubscribe pages were
  hand-built HTML with inline styles, so a reader who signed up from a styled
  page landed somewhere that looked like a different site. They now use
  `Layouts.public` and the confirmation page's card, like the confirmation
  page already did. Routes, status codes, wording and the unsubscribe
  one-click are unchanged.
  ([#1870](https://github.com/The-Verscienta/kiln_cms/issues/1870))

## Fixed

<a id="the-reranker-scores-relevance-instead-of-10-for-every-pair-and-a-reranker-model"></a>

- **The reranker scores relevance instead of 1.0 for every pair, and a reranker
  model that cannot be loaded no longer stops Kiln from booting.** A
  cross-encoder reranker (`BAAI/bge-reranker-base`, the default) has a single
  output logit, and Bumblebee's text classification defaults to softmax, which
  over one logit is exactly 1.0. So a reranked section kept its fused order, but
  every hit's score became 1.0. `/api/ask` then sorted sources across content
  types by those tied scores and fell back to registry order: the bug its flat
  sort was written to fix. `KilnCMS.Search.RerankerServing` now builds the
  serving with `scores_function: :sigmoid` for a single-logit head
  (`scores_function/1`), so a score is a 0–1 relevance with the logit's order.
  A head with more labels keeps softmax and logs a warning at load.
  Separately, the serving used to load the model with `{:ok, _} =` while
  `KilnCMS.Application` was building its child list. With reranking switched
  on and the model missing from an offline image's cache, the match failed
  and the application crash-looped at boot.
  - `RerankerServing.load/0` now returns `{:error, reason}` instead of raising.
  - `RerankerServing.children/1` turns that into no serving child and a
    `KilnCMS.Config.Report.error/3`, and the application starts without a
    reranker.
  - `RerankerServing.status/0` answers `:off`, `:running` or
    `{:unavailable, reason}` after boot.
  - `KilnCMS.Search.Reranker.Bumblebee.scores/2` answers `{:error, _}`. It now
    also catches the exit from a serving that is not running, and it warns at
    most once a minute, logging the failure's kind and never the query.

  Every surface keeps its fused order, as when reranking is off. `build/0`
  keeps its contract and raises with the reason. One caveat remains: because
  reranking is per section, a section whose rerank call fails keeps fused RRF
  scores while the others carry 0–1 scores, so `/api/ask`'s flat sort mixes
  the two scales (documented in `docs/rag.md`).

<a id="the-plugin-docs-no-longer-promise-hex-or-git-dependency-plugins-a-plugin"></a>

- **The plugin docs no longer promise Hex or git-dependency plugins: a plugin
  compiles only as a `projects/<name>/` directory, and is shared as a git
  repository a site vendors there.**
  ([#1909](https://github.com/The-Verscienta/kiln_cms/issues/1909))

## Security

<a id="ash-3-34-6-aggregate-policies"></a>

- **Ash 3.34.6: an MCP read tool's `count`/`exists`/`aggregate` result no
  longer skips related resources' read policies in its filter.**
  EEF-CVE-2026-101028 (MEDIUM): `Ash.count`, `Ash.exists` and
  `Ash.aggregate` applied only the root resource's read policy, so a filter
  crossing a relationship could test conditions against related rows the
  caller can't read. Kiln's MCP read tools keep AshAi's default parameters,
  which let an API-key holder choose those result types and send a filter.
  `Ash.read` and page counts were not affected.

<a id="subscription-retraction"></a>

- **A `<type>Changed` GraphQL subscription now tells anonymous subscribers
  when a published record is unpublished or archived, as `destroyed`.** A
  retraction is an `:update` to Ash, and ash_graphql resolves an update per
  subscriber through the policy-scoped read: once the record left
  `:published` the anonymous read answered not found, and the batcher
  suppresses not-found results rather than leak that a record exists, so the
  one event a public reader most needs never arrived. The GraphQL guide said
  as much and told readers to poll. `KilnCMS.CMS.Changes.NotifySubscribersWithdrawn`
  now sits beside `NotifyWebhooks event: "unpublished"` on `:unpublish`,
  `:unpublish_scheduled`, `:archive_scheduled` and `:archive` (the last only
  when the record was published) and publishes the same notification a real
  `:destroy` would, so the push arrives as `destroyed` with the id, the one
  arm of the union that needs no read. The contract, now in the guide:
  `destroyed` means the record left the published feed, whether unpublished,
  archived or deleted. A bearer-authed editor also receives the `updated`
  push for the same transition. Archiving a draft stays silent.
  ([#1925](https://github.com/The-Verscienta/kiln_cms/issues/1925))
