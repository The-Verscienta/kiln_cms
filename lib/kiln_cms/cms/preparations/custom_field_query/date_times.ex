defmodule KilnCMS.CMS.Preparations.CustomFieldQuery.DateTimes do
  @moduledoc """
  A `datetime` custom field's filter operands (#2678).

  A write stores a date-time as offset-less ISO-8601 text
  (`KilnCMS.CMS.FieldValue.coerce/2`): a UTC offset is dropped, so the value
  is the wall-clock time as written, and the fractional seconds keep the
  digits the client sent. `.25`, `.250` and `.250000` are therefore three
  different stored strings for one time, and `10:00:00` and `10:00:00.000`
  two.

  An operand is read the same way (`cast/1`): through the write's own
  coercion, so its offset is dropped too and its fractional seconds are kept
  to the microsecond. It is then compared against what a write could have
  stored:

    * `eq`, `not_eq` and each item of `in` take every spelling of the time
      (`spellings/1`, at most seven): `eq` matches any of them, `not_eq` none.
    * The range operators compare the stored text against one spelling
      (`bound/2`), which orders every stored spelling correctly: stored
      values share the fixed-width `YYYY-MM-DDTHH:MM:SS` prefix, then an
      optional `.` and one to six digits, so a longer fraction sorts after a
      shorter one it extends. `gt` and `lte` take the six-digit spelling (a
      stored `.25` equals `.250000` and is not after it), `gte` and `lt` the
      shortest (a stored `.250` is not before `.25`).
  """

  alias KilnCMS.CMS.FieldValue

  @max_precision 6

  @doc "The most spellings `spellings/1` returns for one time."
  @spec max_spellings() :: pos_integer()
  def max_spellings, do: @max_precision + 1

  @doc """
  `raw` as the write path would read it: `{:ok, naive_datetime}` with its
  fractional seconds kept, or `:error`. A UTC offset is dropped, never
  applied: `12:00:00+02:00` is `12:00:00`, as it would be stored.
  """
  @spec cast(term()) :: {:ok, NaiveDateTime.t()} | :error
  def cast(raw) do
    with {:ok, stored} <- FieldValue.coerce(raw, %{field_type: :datetime}),
         {:ok, naive} <- NaiveDateTime.from_iso8601(stored) do
      {:ok, naive}
    else
      _ -> :error
    end
  end

  @doc """
  Every text a write could have stored for `naive`: no fraction at all when
  it falls on a whole second, then each precision from the fewest digits the
  time needs up to six (`10:00:00.25`, `10:00:00.250`, …, `10:00:00.250000`).
  """
  @spec spellings(NaiveDateTime.t()) :: [String.t()]
  def spellings(%NaiveDateTime{microsecond: {microsecond, _precision}} = naive) do
    for precision <- digits(microsecond)..@max_precision//1 do
      NaiveDateTime.to_iso8601(%{naive | microsecond: {microsecond, precision}})
    end
  end

  @doc """
  The one spelling a range operator `op` compares stored text against: the
  six-digit one for `gt` and `lte`, the shortest for `gte` and `lt`.
  """
  @spec bound(String.t(), NaiveDateTime.t()) :: String.t()
  def bound(op, naive) when op in ~w(gt lte), do: naive |> spellings() |> List.last()
  def bound(op, naive) when op in ~w(gte lt), do: naive |> spellings() |> hd()

  # The fewest fractional digits that spell `microsecond` exactly.
  defp digits(0), do: 0

  defp digits(microsecond) do
    trailing =
      microsecond
      |> Integer.to_string()
      |> String.pad_leading(@max_precision, "0")
      |> String.reverse()
      |> String.to_charlist()
      |> Enum.take_while(&(&1 == ?0))
      |> length()

    @max_precision - trailing
  end
end
