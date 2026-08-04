defmodule KilnCMS.Events.ICS do
  @moduledoc """
  iCalendar (RFC 5545) output for event-shaped content (#480).

  Two shapes, one writer: a single document's `.ics` (what an "Add to calendar"
  link downloads) and a per-type feed (what someone subscribes to).

  ## A recurring event ships as a rule, not as expanded occurrences

  A calendar client understands `RRULE`, and handing it one is both smaller and
  *more correct* than sending 200 expanded `VEVENT`s: the client keeps showing
  occurrences past whatever window Kiln happened to expand, and a subscriber who
  syncs once a year does not silently lose the tail.

  Expansion still exists, for the JSON delivery surface and for "what's on next"
  — but it is not how a calendar wants to be told.

  ## Escaping is not optional and not the same as HTML

  RFC 5545 has its own rules: `\\`, `;`, `,` and newlines are escaped, and lines
  fold at 75 octets. A title containing a comma silently truncates a `SUMMARY`
  in some clients otherwise. Folding counts **octets, not characters** — folding
  mid-codepoint produces a file that some parsers reject and others render as
  mojibake, which is the kind of bug that only shows up in the one calendar app
  you do not have.

  C0 control characters are stripped rather than escaped: they have no
  representation in the format at all, and the same class of character was what
  broke the XML feeds in #486.
  """

  alias KilnCMS.CMS.FieldTypes.DatetimeRange
  alias KilnCMS.Events
  alias KilnCMS.Events.Recurrence

  @product_id "-//KilnCMS//Kiln//EN"
  @fold_at 75

  @doc """
  A complete calendar for `records`.

  `opts`: `:name` (the calendar's display name), `:org_id`, `:url_for` — a
  function from a record to its public URL, used for `URL` and to build a stable
  `UID`.
  """
  @spec calendar([struct()], keyword()) :: String.t()
  def calendar(records, opts \\ []) do
    name = Keyword.get(opts, :name, "Events")

    lines =
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:#{@product_id}",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        "X-WR-CALNAME:#{escape(name)}"
      ] ++
        Enum.flat_map(records, &vevent_lines(&1, opts)) ++
        ["END:VCALENDAR"]

    Enum.map_join(lines, "\r\n", &fold/1) <> "\r\n"
  end

  @doc "A calendar containing one document — the \"add to calendar\" download."
  @spec event(struct(), keyword()) :: String.t()
  def event(record, opts \\ []), do: calendar([record], opts)

  @doc """
  A filename for a document's `.ics`, safe for a `Content-Disposition`.

  Non-ASCII and separators are dropped rather than encoded: a header is not the
  place to discover that a filename needed RFC 5987.
  """
  @spec filename(struct()) :: String.t()
  def filename(record) do
    slug =
      record
      |> Map.get(:slug, "event")
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
      |> String.slice(0, 60)

    if(slug == "", do: "event", else: slug) <> ".ics"
  end

  # --- one VEVENT ------------------------------------------------------------

  defp vevent_lines(record, opts) do
    org_id = Keyword.get(opts, :org_id) || Map.get(record, :org_id)

    case Events.schedule_value(record, org_id) do
      nil ->
        []

      value ->
        case DatetimeRange.to_utc(value) do
          nil -> []
          {start_utc, end_utc} -> vevent(record, value, start_utc, end_utc, org_id, opts)
        end
    end
  end

  defp vevent(record, schedule, start_utc, end_utc, org_id, opts) do
    all_day? = DatetimeRange.all_day?(schedule)
    zone = Map.get(schedule, "time_zone") || Events.default_time_zone()
    url = url_for(record, opts)

    [
      "BEGIN:VEVENT",
      "UID:#{uid(record, url)}",
      "DTSTAMP:#{utc_stamp(DateTime.utc_now())}",
      dtstart(start_utc, zone, all_day?),
      dtend(start_utc, end_utc, zone, all_day?),
      "SUMMARY:#{escape(Map.get(record, :title) || "Event")}"
    ]
    |> maybe(url && "URL:#{escape(url)}")
    |> maybe(description(record))
    |> maybe(rrule_line(record, org_id))
    |> maybe(exdate_line(record, org_id, zone, all_day?))
    |> Kernel.++(["END:VEVENT"])
    # `dtend/4` is legitimately nil for an open-ended event, and it sits in the
    # literal list above rather than the `maybe/2` chain. One reject at the
    # boundary is safer than remembering which producers can return nil.
    |> Enum.reject(&is_nil/1)
  end

  # A local time plus `TZID` rather than a UTC instant: it is what the value
  # means, and it is what lets a client re-derive the right wall time if the
  # zone's rules change after publication.
  defp dtstart(start_utc, zone, false),
    do: "DTSTART;TZID=#{zone}:#{local_stamp(start_utc, zone)}"

  defp dtstart(start_utc, zone, true),
    do: "DTSTART;VALUE=DATE:#{date_stamp(start_utc, zone)}"

  defp dtend(_start, nil, _zone, false), do: nil

  defp dtend(_start, end_utc, zone, false),
    do: "DTEND;TZID=#{zone}:#{local_stamp(end_utc, zone)}"

  # An all-day DTEND is *exclusive* in RFC 5545 — a one-day event ends on the
  # following day. Omitting the +1 makes every all-day event render a day short,
  # which is the classic ICS bug.
  defp dtend(start_utc, end_utc, zone, true) do
    last_day = (end_utc || start_utc) |> DateTime.shift_zone!(zone) |> DateTime.to_date()
    "DTEND;VALUE=DATE:#{Calendar.strftime(Date.add(last_day, 1), "%Y%m%d")}"
  end

  defp rrule_line(record, org_id) do
    case Events.recurrence_rule(record, org_id) do
      nil -> nil
      rule -> "RRULE:#{Recurrence.to_rrule(rule)}"
    end
  end

  # The skipped dates ride as EXDATE so the client honours them too — otherwise
  # a subscriber sees the occurrences an editor explicitly cancelled.
  defp exdate_line(record, org_id, zone, all_day?) do
    case Events.recurrence_rule(record, org_id) do
      %{ex_dates: [_ | _] = dates} ->
        stamps = Enum.map_join(dates, ",", &Calendar.strftime(&1, "%Y%m%d"))
        if all_day?, do: "EXDATE;VALUE=DATE:#{stamps}", else: "EXDATE;TZID=#{zone}:#{stamps}"

      _other ->
        nil
    end
  end

  defp description(record) do
    case Map.get(record, :seo_description) || Map.get(record, :excerpt) do
      value when is_binary(value) and value != "" -> "DESCRIPTION:#{escape(value)}"
      _other -> nil
    end
  end

  # Stable across regenerations, and globally unique: a client that re-syncs
  # must update the same event rather than accumulate duplicates.
  defp uid(record, url) do
    id = Map.get(record, :id) || :erlang.phash2(url)
    "#{id}@kiln"
  end

  defp url_for(record, opts) do
    case Keyword.get(opts, :url_for) do
      fun when is_function(fun, 1) -> fun.(record)
      _other -> nil
    end
  end

  # --- formatting ------------------------------------------------------------

  defp utc_stamp(datetime), do: Calendar.strftime(datetime, "%Y%m%dT%H%M%SZ")

  defp local_stamp(utc, zone),
    do: utc |> DateTime.shift_zone!(zone) |> Calendar.strftime("%Y%m%dT%H%M%S")

  defp date_stamp(utc, zone),
    do: utc |> DateTime.shift_zone!(zone) |> Calendar.strftime("%Y%m%d")

  @doc false
  # RFC 5545 §3.3.11. Backslash first, or it double-escapes what follows.
  # C0 controls are stripped rather than escaped — the format has no
  # representation for them, the same problem the XML feeds hit in #486.
  def escape(value) do
    value
    |> to_string()
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace(~r/\r\n|\r|\n/, "\\n")
  end

  @doc false
  # RFC 5545 §3.1: fold at 75 **octets**, continuation lines starting with a
  # space. Splitting on characters would fold mid-codepoint on any multi-byte
  # title, producing a file some parsers reject and others render as mojibake.
  def fold(line) do
    if byte_size(line) <= @fold_at do
      line
    else
      line |> take_octets(@fold_at, []) |> Enum.join("\r\n ")
    end
  end

  defp take_octets("", _limit, acc), do: Enum.reverse(acc)

  defp take_octets(rest, limit, acc) do
    {chunk, remainder} = split_at_octets(rest, limit)
    take_octets(remainder, limit - 1, [chunk | acc])
  end

  # Walks graphemes, accumulating while the byte total stays under the limit —
  # so a chunk never ends inside a codepoint.
  defp split_at_octets(string, limit) do
    {taken, _size} =
      string
      |> String.graphemes()
      |> Enum.reduce_while({"", 0}, fn grapheme, {acc, size} ->
        next = size + byte_size(grapheme)
        if next > limit, do: {:halt, {acc, size}}, else: {:cont, {acc <> grapheme, next}}
      end)

    {taken, String.replace_prefix(string, taken, "")}
  end

  defp maybe(lines, nil), do: lines
  defp maybe(lines, line), do: lines ++ [line]
end
