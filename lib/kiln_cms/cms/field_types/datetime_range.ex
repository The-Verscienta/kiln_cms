defmodule KilnCMS.CMS.FieldTypes.DatetimeRange do
  @moduledoc """
  A **datetime range** custom field (#480): when something starts and ends, in a
  named timezone, optionally all-day.

  The `when` half of an event. Composed with `KilnCMS.CMS.FieldTypes.Recurrence`
  for a repeating one and `Geolocation` for a venue, so a dynamic content type
  can *be* an Event without any of those being hardcoded.

  ## Stored shape

      %{
        "start" => "2026-03-15T19:00:00",
        "end" => "2026-03-15T21:00:00",
        "time_zone" => "Europe/London",
        "all_day" => false
      }

  `start`/`end` are **local wall time**, offset-less ISO-8601, paired with an
  IANA zone name. That is deliberate, and it is not how the rest of the codebase
  stores time.

  ## Why local time and a zone, rather than a UTC instant

  `published_at` and friends are `:utc_datetime_usec`, and for an editorial
  timestamp that is right: the moment is the fact.

  An event is the opposite. "The doors open at 19:00" is a fact about the local
  clock, and the UTC instant is derived from it. Storing UTC loses the
  distinction the moment a government changes its DST rules — a concert stored
  as `18:00Z` silently becomes a 20:00 concert, while `19:00 Europe/London`
  stays a 19:00 concert. It is also what recurrence needs: "every Tuesday at
  19:00" cannot be expressed as repeated addition to an instant
  (`KilnCMS.Events.Recurrence` has the long version).

  So the zone is part of the value, not a display preference. A field with no
  `time_zone` falls back to the deployment default rather than to UTC, because
  "UTC" is almost never what an editor meant.

  ## All-day

  `all_day: true` means the times are ignored and the range covers whole days.
  The `start`/`end` are still stored as datetimes (at midnight) so one shape
  serves both, and ICS renders them as `VALUE=DATE`, which is what makes an
  all-day event show as a banner rather than a midnight-to-midnight block.

  ## Accepted input

    * the editor's part map (`start`, `end`, `time_zone`, `all_day`);
    * a stored map round-tripped by an API client, atom or string keys;
    * a single ISO-8601 string, which is a zero-length range starting then —
      and is what a definition's `default` must be, that column being a string.
  """
  use Kiln.FieldType

  alias KilnCMS.Events

  @impl Kiln.FieldType
  def label, do: "Date & time range"

  @impl Kiln.FieldType
  def cast(value, _definition) do
    with {:ok, parts} <- parts(value),
         {:ok, start_at} <- required_datetime(parts, ["start", "start_at"], "start"),
         {:ok, zone} <- time_zone(parts),
         {:ok, end_at} <- optional_datetime(parts, ["end", "end_at"], "end"),
         :ok <- ordered(start_at, end_at) do
      {:ok,
       %{
         "start" => NaiveDateTime.to_iso8601(start_at),
         "end" => end_at && NaiveDateTime.to_iso8601(end_at),
         "time_zone" => zone,
         "all_day" => truthy?(Map.get(parts, "all_day"))
       }
       |> Map.reject(fn {_key, v} -> is_nil(v) end)}
    end
  end

  @impl Kiln.FieldType
  def input_parts(_definition) do
    [
      %{key: "start", label: "Starts", type: "datetime-local", attrs: %{}},
      %{
        key: "end",
        label: "Ends",
        type: "datetime-local",
        required?: false,
        attrs: %{}
      },
      %{
        key: "time_zone",
        label: "Timezone",
        type: "text",
        required?: false,
        attrs: %{placeholder: Events.default_time_zone()}
      },
      # The editor's composite renderer treats a `checkbox` part as a real
      # checkbox — fixed `value="true"`, `checked` from the stored value, plus a
      # hidden `false` companion so unticking submits something. `truthy?/1`
      # below accepts either spelling, since a value also arrives as a real
      # boolean when it is round-tripped out of jsonb.
      %{key: "all_day", label: "All day", type: "checkbox", required?: false, attrs: %{}}
    ]
  end

  @doc """
  The range as UTC instants: `{start, end_or_nil}`.

  The conversion every consumer needs — ICS, JSON-LD, "is this on next week?" —
  so it lives here rather than being re-derived from the stored parts. `nil`
  when the value is not a range this module produced.
  """
  @spec to_utc(term()) :: {DateTime.t(), DateTime.t() | nil} | nil
  def to_utc(%{"start" => start_iso} = value) when is_binary(start_iso) do
    zone = Map.get(value, "time_zone") || Events.default_time_zone()

    with {:ok, naive} <- NaiveDateTime.from_iso8601(start_iso),
         {:ok, start_utc} <- Events.to_utc(naive, zone) do
      {start_utc, end_utc(Map.get(value, "end"), zone)}
    else
      _other -> nil
    end
  end

  def to_utc(_value), do: nil

  @doc "Whether a stored value is an all-day range."
  @spec all_day?(term()) :: boolean()
  def all_day?(%{"all_day" => true}), do: true
  def all_day?(_value), do: false

  defp end_utc(nil, _zone), do: nil

  defp end_utc(iso, zone) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(iso),
         {:ok, utc} <- Events.to_utc(naive, zone) do
      utc
    else
      _other -> nil
    end
  end

  # --- casting ---------------------------------------------------------------

  # `not is_struct` matters: a bare `is_map` guard admits a `%DateTime{}` from a
  # seed or MCP caller, and `Map.new/2` over it raises where `cast/2` owes an
  # `{:error, message}`.
  defp parts(value) when is_map(value) and not is_struct(value),
    do: {:ok, Map.new(value, fn {k, v} -> {to_string(k), v} end)}

  defp parts(%DateTime{} = value), do: {:ok, %{"start" => DateTime.to_iso8601(value)}}
  defp parts(%NaiveDateTime{} = value), do: {:ok, %{"start" => NaiveDateTime.to_iso8601(value)}}
  defp parts(value) when is_binary(value), do: {:ok, %{"start" => value}}
  defp parts(_value), do: {:error, format_message()}

  defp required_datetime(parts, keys, name) do
    case fetch_first(parts, keys) do
      nil -> {:error, "#{name} is required — give a date and time"}
      raw -> parse_datetime(raw, name)
    end
  end

  defp optional_datetime(parts, keys, name) do
    case fetch_first(parts, keys) do
      nil -> {:ok, nil}
      raw -> parse_datetime(raw, name)
    end
  end

  defp fetch_first(parts, keys),
    do: Enum.find_value(keys, &present_datetime(Map.get(parts, &1)))

  defp present_datetime(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp present_datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp present_datetime(_value), do: nil

  # An offset in the input is dropped, not honoured. The pair (local time, zone)
  # is the value; accepting `19:00+02:00` alongside `time_zone: Europe/London`
  # would store two contradictory answers and silently prefer one.
  defp parse_datetime(raw, name) do
    trimmed = String.trim(raw)

    case NaiveDateTime.from_iso8601(trimmed) do
      {:ok, naive} ->
        {:ok, naive}

      _error ->
        # `datetime-local` submits `2026-03-15T19:00` with no seconds.
        case NaiveDateTime.from_iso8601(trimmed <> ":00") do
          {:ok, naive} -> {:ok, naive}
          _error -> {:error, "#{name} must be a date and time like 2026-03-15T19:00"}
        end
    end
  end

  defp time_zone(parts) do
    case Map.get(parts, "time_zone") || Map.get(parts, "timezone") do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" -> {:ok, Events.default_time_zone()}
          Events.known_time_zone?(trimmed) -> {:ok, trimmed}
          true -> {:error, "#{trimmed} isn't a known timezone name (e.g. Europe/London)"}
        end

      _other ->
        {:ok, Events.default_time_zone()}
    end
  end

  defp ordered(_start_at, nil), do: :ok

  defp ordered(start_at, end_at) do
    if NaiveDateTime.compare(end_at, start_at) == :lt,
      do: {:error, "the end must not be before the start"},
      else: :ok
  end

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when is_binary(value), do: String.downcase(value) in ~w(true 1 on yes)
  defp truthy?(_value), do: false

  defp format_message,
    do: "must be a date and time, or a start/end pair"
end
