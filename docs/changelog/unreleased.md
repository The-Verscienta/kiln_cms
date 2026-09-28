# KilnCMS Unreleased — full release notes

The long-form entries behind the Unreleased section of
[CHANGELOG.md](../../CHANGELOG.md), as they were written when each change
merged. `CHANGELOG.md` carries the one-line summary of each; this file
carries the reasoning.

## Changed

<a id="console-lists-share-one-empty-state-long-settings-pages-get-a-table-of-contents"></a>

- **Console lists share one empty state; long settings pages get a table of
  contents; screen crumbs point at their real parent.** Trash (content and
  media), Taxonomy, Inbox, the search palette, Governance, Team, Social,
  Experiments, Newsletter, Webhook deliveries, Federation followers and Form
  Builder entries now render the kit `<.empty_state>` — a title, one line on
  what will appear there and, where there is one, the next step (Inbox's
  empty Unread filter offers "Show all notifications") — instead of a bare
  muted sentence. Your settings, Outgoing mail and Mail carry an "On this page"
  contents: plain anchor links to the page's own section ids, sticky in a right
  column on wide screens and a row of chips on narrow ones, no JavaScript. The
  Form Builder's section switcher is the kit `.tabs` with the full ARIA tabs
  pattern (tablist/tab/tabpanel, `aria-selected`, roving `tabindex`,
  Left/Right/Home/End). And the "← All content" crumb that sixteen non-content
  screens (Team, Billing, Mail, Webhooks, …) carried now names the screen's
  parent, read from `KilnCMSWeb.ConsoleNav`: the Configure hub section it is
  listed under, or Home
  ([#1678](https://github.com/The-Verscienta/kiln_cms/issues/1678),
  [#1680](https://github.com/The-Verscienta/kiln_cms/issues/1680)).
