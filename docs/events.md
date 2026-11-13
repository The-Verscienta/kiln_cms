# Events

Kiln has no `Event` resource, and that is the design.

An event is a content type that carries a **`datetime_range`** field. You
compose one at `/editor/types` and `/editor/fields`; everything downstream —
occurrence expansion, `.ics` output, `schema.org/Event` structured data — keys
on the presence of that field rather than on a hardcoded type name. A venue's
"Gig", a studio's "Workshop" and a school's "Open Day" are three types with
three field sets and one calendar mechanism.

## Composing an event type

```elixir
{:ok, td} = CMS.create_type_definition(%{
  name: "gig", label: "Gig", plural_label: "gigs", path_segment: "gigs",
  # Optional. Gets you a schema.org Event node on the fired :json_ld surface.
  schema_org_type: "Event"
}, actor: admin)

CMS.create_field_definition!(%{
  type_definition_id: td.id, name: "when", label: "When",
  field_type: :datetime_range
}, actor: admin)

# Optional — only for types whose events repeat.
CMS.create_field_definition!(%{
  type_definition_id: td.id, name: "repeats", label: "Repeats",
  field_type: :recurrence
}, actor: admin)
```

A type with a `datetime_range` field is event-shaped. The *first* such field is
the schedule if a type has several — one calendar entry per document, not per
field.

## `datetime_range`: local wall time plus a zone

```elixir
%{
  "start" => "2026-03-15T19:00:00",
  "end" => "2026-03-15T21:00:00",
  "time_zone" => "Europe/London",
  "all_day" => false
}
```

`start` and `end` are **local wall time**, offset-less, paired with an IANA zone
name. This is deliberately not how the rest of Kiln stores time — `published_at`
and friends are UTC instants, because for an editorial timestamp the moment *is*
the fact.

An event is the opposite. "The doors open at 19:00" is a fact about the local
clock and the UTC instant is derived from it. Store UTC and the event silently
moves the next time a government changes its DST rules: `18:00Z` becomes a 20:00
concert, while `19:00 Europe/London` stays a 19:00 concert.

The zone is part of the value, not a display preference. A value naming no zone
falls back to the deployment default:

```elixir
config :kiln_cms, KilnCMS.Events, time_zone: "Europe/London"
```

which itself defaults to `Etc/UTC` — honest rather than helpful. An operator
running a venue should set it.

`all_day: true` means the times are ignored and the range covers whole days.

## `recurrence`: an RRULE subset

```elixir
%{"rrule" => "FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20261231",
  "exdates" => ["2026-12-25"]}
```

Supported: `FREQ` (`DAILY` `WEEKLY` `MONTHLY` `YEARLY`), `INTERVAL`, `COUNT`,
`UNTIL`, `BYDAY`, `BYMONTHDAY`, `BYMONTH`, and `WKST=MO`. Anything else —
`BYSETPOS`, `BYWEEKNO`, `BYYEARDAY`, `BYHOUR`, `BYMINUTE`, `BYSECOND`, a week
start other than Monday — is **rejected at the form**, never silently ignored:
an editor who writes a rule Kiln cannot honor should find out then, not from a
subscriber asking why the calendar is wrong.

`UNTIL` is a **date**, inclusive, in the event's own zone: `UNTIL=20261231`
keeps an occurrence on 31 December at any time of day. A date-time `UNTIL`
(`20261231T000000Z`) is accepted, but only its date is read, and the form saves
it as that date.

Expansion is **wall-clock**, so "every Tuesday at 19:00" stays at 19:00 local
across a DST boundary rather than drifting to 18:00 or 20:00. Where a local time
does not exist (the spring-forward gap) the occurrence moves forward past the
gap; where it happens twice (autumn), the first is used.

Expansion is always windowed and always capped — there is no "all occurrences of
this document" call, because `FREQ=DAILY` with no `UNTIL` has infinitely many.

The `duration` recurs, not the end instant: an event that runs 19:00–21:00 runs
two hours on every occurrence, including one on the far side of a DST change
where the two UTC offsets differ.

### How a rule expands

Kiln expands a rule the way RFC 5545 (§3.3.10) and calendar clients do. That
matters twice over: the "what's on" listing sorts by Kiln's expansion, while a
subscribed calendar receives the rule text and expands it itself, so the two
only agree if both read the rule the same way.

- **`FREQ` sets the period** the rule repeats in: a day, a Monday-start week, a
  calendar month or a calendar year, stepped by `INTERVAL` from the event's
  start.
- **Every other part narrows it.** A date is an occurrence when it passes every
  part the rule gives: its month is in `BYMONTH`, its day in `BYMONTHDAY`
  (negative counts from the month's end, `-1` is the last day), its weekday in
  `BYDAY`. So `BYDAY` with `BYMONTHDAY` is the dates that are both:
  `FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13` is every Friday the 13th. And
  `BYMONTH` narrows daily and weekly rules too: `FREQ=DAILY;BYMONTH=6` is every
  day of June.
- **A numbered `BYDAY`** (`2TU`, `-1FR`, from 1 to 5 either way) counts within
  the month for a monthly rule, and for a yearly rule with `BYMONTH`. A yearly
  rule without `BYMONTH` counts within the **year**: `FREQ=YEARLY;BYDAY=2TU`
  is the second Tuesday of January, and `FREQ=YEARLY;BYDAY=-1FR` the last
  Friday of December. Add `BYMONTH` to name a month:
  `FREQ=YEARLY;BYMONTH=11;BYDAY=4TH` is the fourth Thursday of November.
- **What the rule leaves out comes from the event's start date.** A weekly rule
  with no `BYDAY` repeats on the start's weekday; a monthly rule with neither
  `BYDAY` nor `BYMONTHDAY` on the start's day of the month; a bare yearly rule
  on the start's month and day; a yearly rule with only `BYMONTH` on the
  start's day of those months. A yearly rule with `BYMONTHDAY` or `BYDAY` and
  no `BYMONTH` takes no month from the start: it ranges over the whole year.
- **A date a month doesn't have is skipped**, not moved: a yearly event that
  starts on 29 February repeats in leap years only, and `BYMONTHDAY=31` skips
  the short months.
- **`COUNT` counts real dates from the start**, before `EXDATE` takes any out,
  so `COUNT=10` with one skipped date is nine occurrences, here and in every
  client. Naming a weekday twice (`BYDAY=MO,MO`) is one date, not two.

Some rules and what they produce:

| Rule | Occurrences |
| --- | --- |
| `FREQ=YEARLY;BYMONTH=3,9` | every year in March and September, on the start's day of the month |
| `FREQ=YEARLY;BYMONTHDAY=15` | the 15th of **every** month (add `BYMONTH=` for once a year) |
| `FREQ=YEARLY;BYDAY=TU` | every Tuesday of the year |
| `FREQ=YEARLY;BYDAY=2TU` | the second Tuesday of January |
| `FREQ=YEARLY;BYMONTH=5;BYDAY=2TU` | the second Tuesday of May |
| `FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13` | Friday the 13th, whenever it falls |
| `FREQ=WEEKLY;BYDAY=SA;BYMONTH=6,7,8` | Saturdays in June, July and August |

**The start date is not an occurrence unless it matches the rule.** An event
that starts on Monday 2 March with `FREQ=MONTHLY;BYMONTHDAY=15` first happens
on 15 March: Kiln does not list 2 March, and does not count it toward `COUNT`.
This follows python-dateutil and rrule.js; RFC 5545 calls such a start
undefined in one place (§3.8.5.3) and the first instance in another (§3.3.10),
so some clients, Google Calendar among them, show the start date as an extra
occurrence. Start the event on its first real date to avoid the difference.

Where Kiln knowingly differs from RFC 5545:

- **A local time that doesn't exist** (the spring-forward gap) moves forward
  past the gap; the RFC drops that occurrence.
- **The start date**, as above.
- **A date-time `UNTIL`** is read as the date it names and compared
  inclusively in local time: `UNTIL=20261224T000000Z` keeps a 09:00 New York
  occurrence on 24 December, which the RFC drops. Write `UNTIL` as a date and
  the question doesn't arise.

A rule the form refuses says why. The messages an editor can see include:

| Message | Meaning |
| --- | --- |
| `BYDAY 6TU: the number before the weekday must be 1..5 or -1..-5` | A numbered weekday out of range, or `0TU`. |
| `an ordinal BYDAY like 2TU only works with MONTHLY or YEARLY` | A numbered weekday in a daily or weekly rule. |
| `BYDAY isn't supported with FREQ=DAILY — use FREQ=WEEKLY` | Daily rules can't pick weekdays. |
| `BYMONTHDAY isn't supported with FREQ=WEEKLY — use FREQ=MONTHLY` | Weekly rules can't pick days of the month (daily rules get the same message with `FREQ=DAILY`). |
| `use COUNT or UNTIL, not both` | A rule may end one way only. |
| `WKST=SU isn't supported — weeks start on Monday` | Any week start but `MO`. |
| `BYSETPOS isn't supported` | Likewise `BYWEEKNO`, `BYYEARDAY`, `BYHOUR`, `BYMINUTE`, `BYSECOND`. |

## Calendars

| Path | What it carries |
| --- | --- |
| `/calendar.ics` | every event-shaped type |
| `/<plural>/calendar.ics` | one type |
| `/<plural>/tags/<tag>/calendar.ics` | one type, one taxonomy term |
| `/<plural>/<slug>/calendar.ics` | one document (the "add to calendar" download) |

Published **and `audience: :public`** only. A subscribed calendar is fetched by
an anonymous client on a timer, forever, so gated content is filtered out
explicitly rather than left to a read policy staying shaped as it is today.

A recurring event ships as an `RRULE`, not as expanded `VEVENT`s. A calendar
client understands rules, so this is both smaller and *more correct*: the client
keeps showing occurrences past whatever window Kiln happened to expand, and a
subscriber who syncs once a year does not lose the tail. Skipped dates ride as
`EXDATE`, so a cancelled occurrence stays cancelled on the client too.

Responses are cached for five minutes, carry a matching `Cache-Control`, and are
dropped by the same publish hooks that drop the Atom feeds. Delivery pages
advertise them with `<link rel="alternate" type="text/calendar">`, so a client
finds the calendar without being handed the URL.

A recurring event's `UNTIL` and `EXDATE` are rendered in `DTSTART`'s own value
type — DATE for an all-day event, DATE-TIME otherwise. A date-only `EXDATE` on
a 19:00 event matches no occurrence, which is the classic way a cancelled date
comes back, so a timed `EXDATE` carries the event's local time.

A timed `UNTIL` is the **last second of the `UNTIL` date in the event's zone**,
written in UTC, because that is how Kiln reads `UNTIL`: the whole local day is
included. A weekly 19:00 Europe/London event with `UNTIL=20260405` is exported
with `UNTIL=20260405T225959Z` (London is on summer time by then, so the
day ends at 23:00 UTC), so an occurrence at any time on 5 April is in the
series in both Kiln and the subscriber's calendar, and none on the 6th is. If the event's zone isn't one the
server knows, the `UNTIL` falls back to the DATE form rather than failing the
feed.

## What's on: the occurrence-sorted index

| Path | What it carries |
| --- | --- |
| `/<plural>` | one type's upcoming events as HTML, soonest first |
| `/<plural>/index.json` | the same list as JSON |

Same filter as the calendars — published, `audience: :public`, unlocked, one
locale — and the same reason for it. Both accept:

| Parameter | Meaning |
| --- | --- |
| `?from=` | window start; a date (`2026-09-01`) or a full ISO-8601 instant |
| `?until=` | window end, inclusive by date |
| `?page=` | 1-based page number |

A bare date is read as a **local** day in the deployment's event timezone, not a
UTC one — `?until=2026-09-30` means through the end of the 30th where the events
are, which for a site east of Greenwich is not the same thing.

`?from=` is clamped forward to the start of the current local day; the JSON
response echoes the window that was actually applied. Nothing earlier is stored,
so a request for last year would otherwise answer with this year's events while
appearing to have searched.

### How the ordering works, and what it cannot do

"Next occurrence" is a function of `now()`, so it is not something `sort:` can
reach. Kiln stores it: `next_occurrence_at` is written on every save from the
document's schedule and recurrence, and an hourly Oban sweep
(`KILN_OCCURRENCE_SWEEP_CRON`, default `50 * * * *`) advances rows whose
occurrence has gone by. Ordering and paging then happen in Postgres over an
index, so an anonymous request expands no recurrences at all.

### Recomputing stored dates at boot

The migration adds the column; it cannot fill it, because the value comes out of
the recurrence engine rather than out of other columns. Neither does the sweep —
it visits rows whose occurrence has **passed**, and a `NULL` has not passed
anything. So on a site that had events before upgrading, nothing would ever
compute a first value.

**This is handled for you.** Booting enqueues a backfill job
(`KilnCMS.Events.BackfillWorker`) on its own Oban queue, `occurrence_backfill`,
to run ten minutes later, so the first deploy after upgrading fills the column
and the index works with no upgrade step. A deployment that builds Oban's
`queues:` list itself must include `occurrence_backfill: 1`, or the job is
queued and never runs.

The same job recomputes **every** stored date when a release changes how rules
expand. A stored future date is otherwise right until it passes, so nothing
else would revisit it. Each job carries the recurrence engine's version
(`KilnCMS.Events.Recurrence.engine_version/0`), and the job is deduplicated per
engine version per day at the database level: a rolling deploy across
replicas queues one between them, a restart loop cannot re-trigger it more
than daily, and a release with a new engine always gets its own run even if
the previous release's ran an hour earlier. The ten-minute delay lets nodes of
the previous release, which still compute dates the old way on every save,
leave the cluster first. An edit saved on one of them after the pass keeps the
old engine's date until a boot more than a day later, or a manual run.

Because a redundant pass writes nothing, this doubles as a **repair** pass: a
value knocked out of sync by a direct database edit is corrected on the next
boot rather than persisting until someone notices. (Restoring an event from the
trash recomputes its date itself, since the pass reads live rows only.)

When the pass writes anything it logs one line, for example:

```text
occurrence backfill recomputed 14 record(s) of 220 scanned (recurrence engine 2); 9 moved to a different date: <ids>; 2 now have no upcoming date and left the what's-on listings: <ids>
```

Up to 50 ids are listed for each; the counts are exact. The line is a warning
when any event now has no upcoming date, because those events have dropped out
of `/<plural>`, and info otherwise. A row whose date changes gets a new
`updated_at`, as any save does.

Set `KILN_OCCURRENCE_BACKFILL_ON_BOOT=false` to turn it off and run it yourself,
at a time you choose:

```bash
mix kiln.occurrences.backfill
```

Or, in a release image (no Mix), on the running node:

```bash
bin/kiln_cms rpc 'KilnCMS.Events.Backfill.run() |> IO.inspect()'
```

`rpc`, not `eval`: `eval` starts a bare VM without the application, and the
pass needs the running app's caches. It returns
`%{scanned: …, written: …, moved: [ids], cleared: [ids]}`.

Idempotent, interruptible, and safe on a live site: it writes only the rows
whose value actually changes, so a second run writes nothing. `--org <uuid>`
scopes it to one site, `--batch <n>` sizes the pages.

`--all-types` widens it beyond event-shaped types. That matters in exactly one
case: a type that **lost** its `datetime_range` field while holding
future-dated values. Those rows are invisible to the sweep (their value has not
passed) and to the default pass (their type is no longer event-shaped), so
nothing else will ever correct them. It costs a full scan of every content
table, which is why it is not the default.

Two consequences worth knowing:

* **The sweep's period is the staleness window.** An event that has finished
  keeps its place in the listing until the next run. Shorten the cron on a site
  whose events turn over during the day.
* **Only the next occurrence is stored.** A window that starts in the future
  selects documents whose *next* date falls inside it, not every recurrence
  inside it — so a weekly gig happening tomorrow does not appear under
  `?from=` next month, even though it recurs into that month. Listing individual
  occurrences as addressable items is a different feature (an occurrence table),
  and deliberately not this one.

A page whose slug is a type's URL segment wins over the generated index at that
address, so an operator can replace the listing with a hand-built one.
`Validations.SlugAvailable` normally refuses that collision outright; the
precedence matters for a type given the segment of a page that already exists.

## Structured data

A type declaring one of the schema.org Event types (`Event`, `MusicEvent`,
`Festival`, `TheaterEvent`, `ScreeningEvent`, `CourseInstance`, …) fires an
Event node on the `:json_ld` surface, carrying `startDate`, `endDate`, and — for
a recurring event — `eventSchedule`, a schema.org `Schedule` holding the RRULE
verbatim.

An Event node carries `name` and **not** `articleBody` or `text`: those are
`CreativeWork` properties, and emitting one makes the node invalid rather than
merely verbose.

Declaring `Event` on a type with no `datetime_range` field is allowed and
produces an Event with no dates. The type is what an operator says it is.

## What is not here yet

**A single occurrence is not addressable.** "The 14 March instance of a weekly
gig" has no URL of its own, cannot be cancelled independently of the rule that
generates it (only skipped, via `EXDATE`), and cannot carry its own venue or
price. That needs an occurrence table — one row per expanded occurrence inside a
rolling horizon — which is a bigger thing than the sort key
[#766](https://github.com/The-Verscienta/kiln_cms/issues/766) shipped and was
deliberately not built alongside it.
