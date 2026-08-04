# Events

Kiln has no `Event` resource, and that is the design.

An event is a content type that carries a **`datetime_range`** field. You
compose one at `/editor/types` and `/editor/fields`; everything downstream —
occurrence expansion, `.ics` output, `schema.org/Event` structured data — keys
on the presence of that field rather than on a hardcoded type name. A venue's
"Gig", a clinic's "Workshop" and a school's "Open Day" are three types with
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
%{"rrule" => "FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20261231T000000Z",
  "exdates" => ["2026-12-25"]}
```

Supported: `FREQ` (`DAILY` `WEEKLY` `MONTHLY` `YEARLY`), `INTERVAL`, `COUNT`,
`UNTIL`, `BYDAY`, `BYMONTHDAY`, `BYMONTH`, `WKST`. Anything else — `BYSETPOS`,
`BYWEEKNO`, `BYYEARDAY`, `BYHOUR`, `BYMINUTE`, `BYSECOND` — is **rejected at the
form**, never silently ignored: an editor who writes a rule Kiln cannot honour
should find out then, not from a subscriber asking why the calendar is wrong.

Expansion is **wall-clock**, so "every Tuesday at 19:00" stays at 19:00 local
across a DST boundary rather than drifting to 18:00 or 20:00. Where a local time
does not exist (the spring-forward gap) the occurrence moves forward past the
gap; where it happens twice (autumn), the first is used.

Expansion is always windowed and always capped — there is no "all occurrences of
this document" call, because `FREQ=DAILY` with no `UNTIL` has infinitely many.

The `duration` recurs, not the end instant: an event that runs 19:00–21:00 runs
two hours on every occurrence, including one on the far side of a DST change
where the two UTC offsets differ.

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
type — DATE for an all-day event, DATE-TIME at the event's local time otherwise.
A date-only `EXDATE` on a 19:00 event matches no occurrence, which is the
classic way a cancelled date comes back.

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

An occurrence-sorted, paginated delivery index ("what's on, soonest first") is
tracked in [#766](https://github.com/The-Verscienta/kiln_cms/issues/766).
"Next occurrence" is a function of `now()`, so it is not a column anything can
sort on — it needs either a materialized next-occurrence
value with a sweep to keep it fresh, or a SQL-side expansion. Today's ordering
inside a calendar is by publish date, which a calendar client re-sorts by date
itself.
