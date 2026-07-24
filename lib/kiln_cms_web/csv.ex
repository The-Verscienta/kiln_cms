defmodule KilnCMSWeb.CSV do
  @moduledoc """
  Minimal RFC-4180 CSV encoding shared by the exports (governance trail and
  form submissions). Includes the formula-injection guard — a security control
  that must not drift between copies, hence one home.
  """

  @doc "Encodes one row (list of cells) as a CRLF-terminated CSV line."
  @spec line([term()]) :: String.t()
  def line(cells), do: Enum.map_join(cells, ",", &field/1) <> "\r\n"

  @doc """
  Encodes one cell: RFC-4180 quoting (a comma, quote, or newline quotes the
  field; embedded quotes double), plus a leading apostrophe on any value that
  starts with a formula character so a spreadsheet app never executes a cell
  that came from user-entered content (CSV injection).
  """
  @spec field(term()) :: String.t()
  def field(nil), do: ""

  def field(value) do
    value = to_string(value)
    value = if String.match?(value, ~r/\A[=+\-@\t\r]/), do: "'" <> value, else: value

    if String.contains?(value, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(value, "\"", "\"\"") <> "\"",
      else: value
  end
end
