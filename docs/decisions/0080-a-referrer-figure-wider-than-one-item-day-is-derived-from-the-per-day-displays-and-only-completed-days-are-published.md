# 0080. A referrer figure wider than one item-day is derived from the per-day displays, and only completed days are published

- **Status** — accepted (2026-11-21).
- **References** — [#2989](https://github.com/The-Verscienta/kiln_cms/issues/2989)
  (this decision, the owner's analysis and simulation),
  [#2990](https://github.com/The-Verscienta/kiln_cms/issues/2990) (the
  dashboard's note explaining `hidden`), building on
  [ADR 0075](0075-a-referrer-suppression-rule-is-found-by-enumeration-and-judged-per-breakdown-against-a-reader-who-knows-it.md)
  and [#2981](https://github.com/The-Verscienta/kiln_cms/issues/2981) (the
  per-breakdown guarantee). The guides are
  [data-flows.md](../data-flows.md) and
  [environment-variables.md](../environment-variables.md#referrer-attribution-619).
- **Changelog** — 1.12.0, under Changed ([long form](../changelog/v1.12.0.md#referrer-exact-or-hidden)).

## The problem

`KilnCMS.Analytics.suppress_referrer_group/1` protects one breakdown on its own
(ADR 0075). Kiln published several breakdowns of the same arrivals, each
suppressed from its own raw sum: the dashboard's span beside the export's
per-day rows, the site-wide chart beside each item's bar, seven days beside
thirty, and today's bucket, read again as it grew. A reader holding two of them
could subtract one from the other. Day 1 `other: 1` and day 2 `other: 4` were
each hidden whole in the export, but the two-day span showed `other: 5`, which
with the day totals pins both days. The owner's simulation at a threshold of 5
found 3,436 joint classes of two days with up to six views each that pin a
per-day cell.

## The decision

Suppression decides one content item's one completed UTC day, and nothing
wider. `Analytics.published_referrer_cells/2` decides each item-day in a read,
and `Analytics.derive_referrer_group/1` turns any set of them into a wider
figure: per category, the sum of the displays when every cell shows an
integer, and `"hidden"` otherwise. The raw hits are never summed into anything
published.

A figure computed only from what the per-day breakdowns already publish can
tell a reader nothing those breakdowns did not, so any combination of
figures is as safe as one breakdown on its own.
`test/kiln_cms/analytics/referrer_differencing_test.exs` checks this by brute
force over every pair of item-days with up to six views at a threshold of 5,
and shows the raw-sum version failing the same check.

Only days up to `Analytics.last_published_referrer_day/0` (yesterday) are
published, on the dashboard and in the export. A completed day never changes,
so every read of it is the same.

## What it costs

On small sites, a lot. One day with a `"< n"` or `"hidden"` category hides that
category for the whole span. At 3 views a day, a 30-day item span went from 78%
exact to 0%; at 100 views a day, a 7-day span from 100% to 51%. In the
simulation the site-wide chart went from always exact to never. Today's referrers appear tomorrow. The dashboard now
explains `hidden` when anything is (#2990).

## Rejected

- **Derived ranges `[lo, hi]`** instead of `hidden`. Equally safe, and more
  informative at moderate traffic, but a new display shape on every surface.
- **A weekly fixed grain** for the export and the dashboard. Exact more often
  at 10 to 30 views a day, but it changes the export's grain and the
  dashboard's ranges.
- **Re-suppressing the span** from its raw sum. The decision still depends on
  raw sums, which is the leak.
- **Dropping per-day rows from the export.** An arbitrary `from..to` export
  re-creates them.
- **Percentages or rounding.** They leak bounds.
