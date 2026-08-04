defmodule KilnCMS.CMS.FieldTypes.Recurrence do
  @moduledoc """
  A **recurrence** custom field (#480): how often an event repeats, as an RFC
  5545 RRULE subset.

  Pairs with `KilnCMS.CMS.FieldTypes.DatetimeRange`, which supplies the start
  the rule repeats *from*. A recurrence on a document with no schedule field has
  nothing to expand and is inert — harmless, but `KilnCMS.Events.event_type?/2`
  keys on the schedule for that reason.

  ## Stored shape

      %{"rrule" => "FREQ=WEEKLY;BYDAY=TU", "exdates" => ["2026-04-07"]}

  The RRULE is stored **normalized** — parsed and re-rendered by
  `KilnCMS.Events.Recurrence` — so storage carries one spelling of a rule rather
  than whatever an editor pasted. `RRULE:freq=weekly` and `FREQ=WEEKLY` are the
  same rule and become the same string.

  ## Validation happens at cast, not at render

  An unsupported part (`BYSETPOS`, `FREQ=SECONDLY`) is an error on save, with a
  message naming the part. The alternative — accepting it and ignoring it later
  — gives an editor a calendar that is wrong in a way nothing surfaces, which is
  the failure mode this field is most likely to have.

  It is also why expansion never has to defend against a malformed rule: nothing
  malformed reaches storage.

  ## Accepted input

    * the editor's part map (`rrule`, `exdates`);
    * a stored map round-tripped by an API client;
    * a bare RRULE string, which is what a definition's `default` must be.
  """
  use Kiln.FieldType

  alias KilnCMS.Events.Recurrence

  @max_exdates 200

  @impl Kiln.FieldType
  def label, do: "Recurrence"

  @impl Kiln.FieldType
  def cast(value, _definition) do
    with {:ok, parts} <- parts(value),
         {:ok, rrule} <- rrule(parts),
         {:ok, exdates} <- exdates(parts) do
      {:ok, %{"rrule" => rrule, "exdates" => exdates}}
    end
  end

  @impl Kiln.FieldType
  def input_parts(_definition) do
    [
      %{
        key: "rrule",
        label: "Repeats",
        type: "text",
        attrs: %{placeholder: "FREQ=WEEKLY;BYDAY=TU"}
      },
      %{
        key: "exdates",
        label: "Skip these dates",
        type: "text",
        required?: false,
        attrs: %{placeholder: "2026-04-07, 2026-12-25"}
      }
    ]
  end

  @doc """
  The parsed rule for a stored value, or `nil`.

  Never raises on a stored value — but a value that fails to parse here means
  something bypassed `cast/2`, so it is `nil` rather than an error: a document
  with an unreadable rule renders as a one-off event, not as a 500.
  """
  @spec rule(term()) :: Recurrence.t() | nil
  def rule(%{"rrule" => rrule}) when is_binary(rrule) do
    case Recurrence.parse(rrule) do
      {:ok, parsed} -> parsed
      {:error, _reason} -> nil
    end
  end

  def rule(_value), do: nil

  @doc """
  The parsed rule with the separate `exdates` list folded into it.

  This is what callers want — `rule/1` is the raw parse, and an RRULE's own
  inline `EXDATE=` part is already in it; this adds the editor-facing list.
  """
  @spec rule_with_exdates(term()) :: Recurrence.t() | nil
  def rule_with_exdates(%{"exdates" => exdates} = value) when is_list(exdates) do
    case rule(value) do
      nil -> nil
      parsed -> %{parsed | ex_dates: Enum.uniq(parsed.ex_dates ++ parse_dates(exdates))}
    end
  end

  def rule_with_exdates(value), do: rule(value)

  # --- casting ---------------------------------------------------------------

  defp parts(value) when is_map(value) and not is_struct(value),
    do: {:ok, Map.new(value, fn {k, v} -> {to_string(k), v} end)}

  defp parts(value) when is_binary(value), do: {:ok, %{"rrule" => value}}
  defp parts(_value), do: {:error, "must be a recurrence rule like FREQ=WEEKLY;BYDAY=TU"}

  defp rrule(parts) do
    case Map.get(parts, "rrule") do
      value when is_binary(value) ->
        case value |> String.trim() |> normalize() do
          {:ok, normalized} -> {:ok, normalized}
          {:error, message} -> {:error, message}
        end

      _other ->
        {:error, "needs a repeat rule like FREQ=WEEKLY;BYDAY=TU"}
    end
  end

  defp normalize(""), do: {:error, "needs a repeat rule like FREQ=WEEKLY;BYDAY=TU"}

  defp normalize(value) do
    case Recurrence.parse(value) do
      {:ok, rule} -> {:ok, Recurrence.to_rrule(rule)}
      {:error, message} -> {:error, message}
    end
  end

  # Accepts a list (API) or a comma/space-separated string (the editor's text
  # input). Bounded: a rule with thousands of exceptions is a paste accident,
  # and every one of them is compared on every expansion.
  defp exdates(parts) do
    raw =
      case Map.get(parts, "exdates") do
        list when is_list(list) -> list
        value when is_binary(value) -> String.split(value, [",", " ", "\n"], trim: true)
        _other -> []
      end

    dates = raw |> Enum.map(&normalize_date/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    cond do
      length(raw) > @max_exdates ->
        {:error, "no more than #{@max_exdates} skipped dates"}

      length(dates) != length(Enum.reject(raw, &(to_string(&1) |> String.trim() == ""))) ->
        {:error, "skipped dates must look like 2026-04-07"}

      true ->
        {:ok, dates}
    end
  end

  defp normalize_date(value) when is_binary(value) do
    case value |> String.trim() |> Date.from_iso8601() do
      {:ok, date} -> Date.to_iso8601(date)
      _error -> nil
    end
  end

  defp normalize_date(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_date(_value), do: nil

  defp parse_dates(values) do
    values
    |> Enum.map(fn value ->
      case value |> to_string() |> Date.from_iso8601() do
        {:ok, date} -> date
        _error -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
