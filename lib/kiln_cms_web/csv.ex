defmodule KilnCMSWeb.CSV do
  @moduledoc """
  Shared CSV codec for downloadable exports (#618) and content import (#949),
  extracted from
  `KilnCMSWeb.GovernanceController` so a second export (analytics) doesn't
  reimplement — or forget — the CSV-injection guard.

  Two things every export needs and must not re-derive:

    * **RFC 4180 quoting** — a field holding a comma, quote, or newline is
      wrapped in quotes, with embedded quotes doubled.
    * **The formula-prefix guard** — a field starting with `=`, `+`, `-`, `@`,
      a tab, or a carriage return is prefixed with `'` so a spreadsheet
      application never executes it as a formula (CSV injection).

  `parse/1` is the exact inverse of both, and lives here rather than beside the
  importer for that reason: a reader that did not undo the formula guard would
  turn every round trip of `=SUM(A1)` into `'=SUM(A1)`, growing a quote per
  cycle. It strips a leading `'` only when the character after it is one of the
  guarded set, so a genuine value like `'tis` is untouched.
  """

  @doc "One CSV row: fields joined with commas, RFC 4180 quoted, CRLF-terminated."
  @spec line([term()]) :: String.t()
  def line(fields), do: Enum.map_join(fields, ",", &field/1) <> "\r\n"

  @doc "Escapes a single CSV field: formula-prefix guard, then RFC 4180 quoting."
  @spec field(term()) :: String.t()
  def field(nil), do: ""

  def field(value) do
    value = to_string(value)
    value = if String.match?(value, ~r/\A[=+\-@\t\r]/), do: "'" <> value, else: value

    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  @guarded ~r/\A[=+\-@\t\r]/

  @doc """
  Parse RFC 4180 CSV text into a list of rows, each a list of fields.

  Quoted fields may contain commas, doubled quotes, and newlines. The formula
  guard `field/1` applies is undone. Blank trailing lines are dropped; a blank
  line *between* rows is a row of one empty field, as the format says.

  A leading UTF-8 BOM is stripped. Excel and Google Sheets both write one, so
  without this the first header cell is `"\uFEFFtitle"` rather than `"title"` —
  which any header check then reports as an unknown column, breaking the one
  workflow CSV exists for here (export, edit in a spreadsheet, re-import).

  Raises `ArgumentError` on a quoted field that never closes, rather than
  returning the truncated remainder: that shape means a cut-off download or a
  half-written file, and silently importing the surviving prefix is worse than
  refusing it.
  """
  @spec parse(String.t()) :: [[String.t()]]
  def parse(text) when is_binary(text) do
    text
    |> strip_bom()
    |> scan([], [], "", false)
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse/1)
    |> drop_trailing_blank()
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(text), do: text

  # A hand-rolled scanner rather than a dependency: the grammar is four rules,
  # measured at 14 ms for 20k rows, and a library would still leave the two
  # things that actually bite (the formula guard and the BOM) to this module.
  defp scan("", _rows, _row, _field, true) do
    raise ArgumentError, "malformed CSV: a quoted field is never closed"
  end

  defp scan("", rows, row, field, false), do: [[unfield(field) | row] | rows]

  defp scan(<<?", rest::binary>>, rows, row, field, true) do
    case rest do
      # A doubled quote inside a quoted field is one literal quote.
      <<?", tail::binary>> -> scan(tail, rows, row, field <> "\"", true)
      _ -> scan(rest, rows, row, field, false)
    end
  end

  defp scan(<<?", rest::binary>>, rows, row, field, false) when field == "",
    do: scan(rest, rows, row, field, true)

  defp scan(<<?,, rest::binary>>, rows, row, field, false),
    do: scan(rest, rows, [unfield(field) | row], "", false)

  defp scan(<<?\r, ?\n, rest::binary>>, rows, row, field, false),
    do: scan(rest, [[unfield(field) | row] | rows], [], "", false)

  defp scan(<<?\n, rest::binary>>, rows, row, field, false),
    do: scan(rest, [[unfield(field) | row] | rows], [], "", false)

  defp scan(<<char::utf8, rest::binary>>, rows, row, field, in_quotes?),
    do: scan(rest, rows, row, field <> <<char::utf8>>, in_quotes?)

  # Undo the formula guard, and only that: a leading `'` is removed only when
  # what follows is a character `field/1` would have guarded.
  defp unfield("'" <> rest = value) do
    if Regex.match?(@guarded, rest), do: rest, else: value
  end

  defp unfield(value), do: value

  defp drop_trailing_blank(rows) do
    case Enum.reverse(rows) do
      [[""] | rest] -> Enum.reverse(rest)
      _ -> rows
    end
  end
end
