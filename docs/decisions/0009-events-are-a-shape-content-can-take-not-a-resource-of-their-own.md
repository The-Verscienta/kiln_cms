# 0009. Events are a shape content can take, not a resource of their own

- **Status** — accepted, shipped in
  [0.5.0](../changelog/v0.5.0.md) (Added).
- **References** — [#766](https://github.com/The-Verscienta/kiln_cms/issues/766), [#480](https://github.com/The-Verscienta/kiln_cms/issues/480).
- **Changelog** — [0.5.0 → Added](../../CHANGELOG.md#050---2026-08-09).

## Decision

**Events: "what's on, soonest first"** (#766). An event-shaped content type —
one carrying a `datetime_range` field (#480) — now has a paginated delivery
index ordered by each document's **next occurrence**, at `/<plural>` (HTML)
and `/<plural>/index.json`. Both take `?from=`/`?until=`/`?page=`; a bare date
is read as a local day in the deployment's event timezone. Details in
[docs/events.md](../events.md).

Same filter as the `.ics` routes, for the same reason: published **and**
`audience: :public`, one locale, unlocked. An anonymous listing that widened
any of that would be a leak rather than a listing.

"Next occurrence" is a function of `now()`, so it is stored: a
`next_occurrence_at` column written on save and advanced by an hourly Oban
sweep (`KILN_OCCURRENCE_SWEEP_CRON`, default `50 * * * *`). **That interval is
how stale the listing may be** — an event that has finished keeps its place
until the next run — so shorten it on a site whose events turn over during the
day.

What it deliberately does not do: only the *next* occurrence is stored, so a
window starting in the future selects documents whose next date falls inside
it, not every recurrence inside it. Making a single occurrence addressable in
its own right is a different feature and is named as such in the docs.
