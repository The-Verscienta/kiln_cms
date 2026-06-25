defmodule KilnCMS.Search.Highlight do
  @moduledoc """
  Safe rendering of the `highlight` calculation's `ts_headline` snippets.

  The `highlight` calculation on `KilnCMS.CMS.Content` returns the matching
  portion of a row's text with the matched terms wrapped in literal `<mark>` …
  `</mark>` tags (see its definition in `content.ex`). Postgres' `ts_headline`
  does **not** HTML-escape the surrounding source text, so the raw value can't be
  rendered as HTML directly — arbitrary content could carry `<`/`>`/`&`.

  `to_safe_html/1` closes that gap: it HTML-escapes the *entire* snippet first —
  neutralising any markup the content carries — and only then reveals the
  `<mark>` pair. The highlight tag is therefore the only live markup in the
  output, regardless of the source text. The admin search palette renders
  snippets through this function.
  """

  # The delimiters `ts_headline` emits (its `StartSel`/`StopSel`). After
  # escaping they appear as `&lt;mark&gt;` / `&lt;/mark&gt;`; we swap those exact
  # sequences back to live tags.
  @escaped_open "&lt;mark&gt;"
  @escaped_close "&lt;/mark&gt;"

  @doc """
  Render a raw `highlight` snippet as safe HTML.

  Escapes everything, then reveals the `<mark>` tags around matched terms.
  Returns a `Phoenix.HTML.safe/0` tuple, so it renders verbatim in HEEx.
  `nil`/blank input renders as empty.
  """
  @spec to_safe_html(String.t() | nil) :: Phoenix.HTML.safe()
  def to_safe_html(snippet) when snippet in [nil, ""], do: Phoenix.HTML.raw("")

  # Safe by construction: the snippet is fully HTML-escaped before only the
  # `<mark>` pair is revealed, so no source markup survives as live HTML.
  # sobelow_skip ["XSS.Raw"]
  def to_safe_html(snippet) when is_binary(snippet) do
    snippet
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace(@escaped_open, "<mark>")
    |> String.replace(@escaped_close, "</mark>")
    |> Phoenix.HTML.raw()
  end
end
