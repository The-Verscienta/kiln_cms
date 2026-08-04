defmodule KilnCMSWeb.CSV do
  @moduledoc """
  Shared CSV writer for downloadable exports (#618), extracted from
  `KilnCMSWeb.GovernanceController` so a second export (analytics) doesn't
  reimplement — or forget — the CSV-injection guard.

  Two things every export needs and must not re-derive:

    * **RFC 4180 quoting** — a field holding a comma, quote, or newline is
      wrapped in quotes, with embedded quotes doubled.
    * **The formula-prefix guard** — a field starting with `=`, `+`, `-`, `@`,
      a tab, or a carriage return is prefixed with `'` so a spreadsheet
      application never executes it as a formula (CSV injection).
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
end
