defmodule KilnCMSWeb.EventIndex do
  @moduledoc """
  The request-shaped half of the "what's on" index (#766): the window a caller
  asked for, and the view maps both delivery surfaces render.

  `KilnCMS.Events.Index` owns the query and the filter; this owns turning
  `?from=`/`?until=`/`?page=` into arguments for it, and turning the rows back
  into something an HTML template and a JSON body can each render without
  either re-deriving the other's shape.

  ## The end time costs no expansion

  A listed occurrence needs more than the instant it starts: whether it is
  all-day, which zone that is in, and when it ends. All three come from the
  document's stored `datetime_range` — the **duration** is what recurs, so the
  end is `next_occurrence_at + duration`, with no recurrence walk anywhere in
  the request.

  The field *definition* that names where the schedule lives is resolved once
  per request, from the descriptor, rather than once per record: that lookup is
  a database read, and doing it per row would put a query per listed event back
  on the anonymous route this whole feature exists to keep queries off.
  """

  alias KilnCMS.CMS.FieldTypes.DatetimeRange
  alias KilnCMS.Events
  alias KilnCMS.Events.Index
  alias KilnCMS.Seo.Patterns
  alias KilnCMSWeb.Params
  alias KilnCMSWeb.Tenant

  @typedoc "One row as both surfaces render it."
  @type entry :: %{
          id: Ash.UUID.t(),
          title: String.t(),
          path: String.t(),
          url: String.t(),
          summary: String.t(),
          starts_at: DateTime.t(),
          ends_at: DateTime.t() | nil,
          all_day?: boolean(),
          time_zone: String.t(),
          recurring?: boolean()
        }

  @doc """
  The event-shaped content type served at `segment`, or `nil`.

  Resolved against `KilnCMS.Events.calendar_types/1` — the cached "which types
  carry a `datetime_range` field" registry the `.ics` routes use — so exactly
  the types that have a calendar have an index, and neither list can drift from
  the other.
  """
  @spec type_for(Ash.UUID.t(), String.t()) :: map() | nil
  def type_for(org_id, segment) do
    org_id
    |> Events.calendar_types()
    |> Enum.find(&(&1.plural == segment or &1.path_segment == segment))
  end

  @doc """
  The occurrence window a request asked for, as `{from, until}`.

  Accepts a date (`2026-09-01`) or a full ISO-8601 instant on either bound. A
  **date** is read as a local one in the deployment's event timezone — whole
  days, `from` at its start and `until` at its end — because that is what an
  event date means everywhere else in Kiln, and a UTC reading would silently
  drop the evening of the last day for any site east of Greenwich.

  `from` never goes earlier than `KilnCMS.Events.Index.anchor/1`. Nothing before
  the anchor is materialized — the sweep advances rows past it — so a request
  for last year would answer with this year's events while appearing to have
  searched. Clamping says what the index can actually do.

  A malformed bound reads as absent rather than as an error, which is what every
  other optional delivery parameter does (`KilnCMSWeb.Params` has the argument).
  """
  @spec window(map()) :: {DateTime.t(), DateTime.t() | nil}
  def window(params) do
    anchor = Index.anchor()
    from = params |> bound("from", :start) |> latest(anchor)

    {from, bound(params, "until", :end)}
  end

  defp latest(nil, anchor), do: anchor

  defp latest(requested, anchor) do
    if DateTime.compare(requested, anchor) == :lt, do: anchor, else: requested
  end

  defp bound(params, key, edge) do
    case Params.string(params, key, "") |> String.trim() do
      "" -> nil
      value -> parse_bound(value, edge)
    end
  end

  # An offset-carrying instant, then a wall time, then a bare date. The order is
  # not arbitrary: `Date.from_iso8601/1` happily parses the date *prefix* of
  # `2026-09-01T19:00:00Z` and would throw the time away, so the widest form has
  # to be tried first.
  defp parse_bound(value, edge) do
    offset_instant(value) || wall_time(value) || local_date(value, edge)
  end

  defp offset_instant(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.shift_zone!(datetime, "Etc/UTC")
      _error -> nil
    end
  end

  # `2026-09-01T19:00:00` — no offset, which everywhere else in Kiln's event
  # handling means a LOCAL wall time. Reading it as UTC would put the same
  # request an hour or thirteen away from what an editor typed into the same
  # shaped field.
  defp wall_time(value) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
         {:ok, utc} <- Events.to_utc(naive, zone()) do
      utc
    else
      _error -> nil
    end
  end

  defp local_date(value, edge) do
    with {:ok, date} <- Date.from_iso8601(value),
         {:ok, utc} <- Events.to_utc(NaiveDateTime.new!(date, time_of_day(edge)), zone()) do
      utc
    else
      _error -> nil
    end
  end

  # Inclusive on both ends: `?until=2026-09-30` means "through the 30th", not
  # "up to the moment it began". `Index.filter/3` compares with `<=`, so the
  # last representable microsecond of the day is the bound that expresses it.
  defp time_of_day(:start), do: ~T[00:00:00.000000]
  defp time_of_day(:end), do: ~T[23:59:59.999999]

  defp zone, do: Events.default_time_zone()

  @doc "Zero-based page index from a 1-based `?page=N`, clamped."
  @spec page(map()) :: non_neg_integer()
  def page(params) do
    case Integer.parse(Params.string(params, "page", "")) do
      {n, _rest} when n > 1 -> min(n - 1, max_page())
      _absent_or_invalid -> 0
    end
  end

  # The deep-page ceiling. Offset paging makes Postgres walk every skipped row,
  # so an unclamped `?page=` on an anonymous route is a cheap way to ask for a
  # very large scan.
  defp max_page, do: 500

  @doc """
  One page of upcoming documents for `descriptor`, as renderable entries plus
  whether there is another page.

  The read itself is `KilnCMS.Events.Index.upcoming/3`, so the audience and
  publication filtering is the one written there — identical to
  `KilnCMSWeb.CalendarController`'s, and not re-derived here.
  """
  @spec fetch(map(), map(), keyword()) :: %{entries: [entry()], more?: boolean()}
  def fetch(descriptor, org, opts) do
    %Ash.Page.Offset{results: records, more?: more?} =
      Index.upcoming(descriptor, org.id, opts)

    scope = Events.scope_for_descriptor(descriptor)
    # Two definition reads for the whole page, not two per row — see the
    # moduledoc.
    schedule = Events.schedule_field(scope, org.id)
    recurrence = Events.recurrence_field(scope, org.id)

    %{
      entries: Enum.map(records, &entry(&1, descriptor, org, schedule, recurrence)),
      more?: more?
    }
  end

  defp entry(record, descriptor, org, schedule, recurrence) do
    value = schedule && Map.get(record.custom_fields || %{}, schedule.name)
    path = locale_prefix(record.locale) <> public_path(record, descriptor)

    %{
      id: record.id,
      title: record.title,
      path: path,
      url: Tenant.base_url(org) <> path,
      summary: summary(record, descriptor, org),
      starts_at: record.next_occurrence_at,
      ends_at: ends_at(record.next_occurrence_at, value),
      all_day?: DatetimeRange.all_day?(value),
      time_zone: time_zone(value),
      recurring?: recurring?(record, recurrence)
    }
  end

  # The DURATION recurs, not the end instant — a 19:00–21:00 event runs two
  # hours on every occurrence, including one on the far side of a DST change
  # where the two UTC offsets differ. So the end is derived from the stored
  # range's length applied to *this* occurrence, never from the stored end.
  defp ends_at(_starts_at, nil), do: nil

  defp ends_at(starts_at, value) do
    case DatetimeRange.to_utc(value) do
      {start_utc, end_utc} when not is_nil(end_utc) ->
        DateTime.add(starts_at, DateTime.diff(end_utc, start_utc, :second), :second)

      _open_ended ->
        nil
    end
  end

  defp time_zone(value) when is_map(value),
    do: Map.get(value, "time_zone") || Events.default_time_zone()

  defp time_zone(_value), do: Events.default_time_zone()

  # Whether the listed date is one of several. Read straight off the already
  # selected `custom_fields` — the rule is not parsed, because nothing here
  # renders it and parsing per row would be work for a boolean.
  defp recurring?(_record, nil), do: false

  defp recurring?(record, definition) do
    case Map.get(record.custom_fields || %{}, definition.name) do
      value when is_map(value) -> map_size(value) > 0
      value when is_binary(value) -> value != ""
      _absent -> false
    end
  end

  # `excerpt` where the type has one, else the SEO description — the two fields
  # an editor already writes as "what this is about", exactly as the feeds pick
  # them. Never a truncated body.
  #
  # The *effective* description (#1102), loaded by `Index.upcoming/3`, so a type
  # that defaults one through a #805 pattern reads the same in this listing as
  # on the page it links to.
  defp summary(record, descriptor, org) do
    [
      Map.get(record, :excerpt),
      Patterns.effective(record, :seo_description, type: descriptor, org: org)
    ]
    |> Enum.find("", &(is_binary(&1) and &1 != ""))
  end

  defp public_path(%{path_alias: alias_path}, _descriptor) when is_binary(alias_path),
    do: alias_path

  defp public_path(record, descriptor),
    do: "#{KilnCMS.CMS.ContentTypes.public_prefix(descriptor)}/#{record.slug}"

  defp locale_prefix(locale) do
    if locale == KilnCMS.I18n.default_locale(), do: "", else: "/#{locale}"
  end

  @doc """
  The path a type's index is served at — shared with the `<link>`/`href`
  builders so the advertised URL and the routed one cannot drift.

  The type's public prefix where it has one, its plural otherwise. NOT
  `public_prefix/1` unguarded, which returns `""` for a type served at the root
  and would put its index at `/`, the site's own home page.
  """
  @spec index_path(map()) :: String.t()
  def index_path(%{path_segment: segment}) when is_binary(segment) and segment != "",
    do: "/" <> segment

  def index_path(%{plural: plural}), do: "/" <> plural

  @doc "The path the JSON equivalent of that index is served at."
  @spec json_path(map()) :: String.t()
  def json_path(descriptor), do: index_path(descriptor) <> "/index.json"
end
