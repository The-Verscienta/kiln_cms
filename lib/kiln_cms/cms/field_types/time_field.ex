defmodule KilnCMS.CMS.FieldTypes.TimeField do
  @moduledoc """
  A **time** custom field (#2278): a time of day with no date and no time zone,
  stored as zero-padded `"HH:MM"` on a 24-hour clock.

  `H:MM`, `HH:MM` and `HH:MM:SS` are accepted; seconds are dropped. The zero
  padding keeps string comparison in time order, so `gt`/`lt` filters and sorts
  behave. For an instant, use a `:datetime` field; for a span, `:datetime_range`.
  """
  use Kiln.FieldType
  use Gettext, backend: KilnCMSWeb.Gettext

  @impl Kiln.FieldType
  def name, do: :time

  @impl Kiln.FieldType
  def label, do: "Time of day"

  @impl Kiln.FieldType
  def description do
    gettext(
      "A time of day such as 09:30, with no date or time zone. For opening hours or when a recurring session starts."
    )
  end

  @impl Kiln.FieldType
  def input_type, do: "time"

  @impl Kiln.FieldType
  def graphql_kind(_definition), do: :string

  @impl Kiln.FieldType
  def json_schema(_definition),
    do: %{"type" => ["string", "null"], "pattern" => "^([01][0-9]|2[0-3]):[0-5][0-9]$"}

  @impl Kiln.FieldType
  def cast(value, _definition) when is_binary(value) do
    with [_, hour, minute | seconds] <-
           Regex.run(~r/\A([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?\z/, String.trim(value)),
         {h, ""} when h in 0..23 <- Integer.parse(hour),
         {m, ""} when m in 0..59 <- Integer.parse(minute),
         true <- seconds_ok?(seconds) do
      {:ok, pad(h) <> ":" <> pad(m)}
    else
      _ -> {:error, message()}
    end
  end

  def cast(_value, _definition), do: {:error, message()}

  defp seconds_ok?([]), do: true
  defp seconds_ok?([second]), do: String.to_integer(second) in 0..59

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  defp message, do: "must be a time of day such as 09:30"
end
