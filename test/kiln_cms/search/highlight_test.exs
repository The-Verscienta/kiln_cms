defmodule KilnCMS.Search.HighlightTest do
  @moduledoc """
  `to_safe_html/1` reveals the `<mark>` tags the `highlight` calc emits while
  neutralizing any HTML the source snippet carries (the source is arbitrary
  content and is not escaped by `ts_headline`).
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Search.Highlight

  defp render(snippet), do: snippet |> Highlight.to_safe_html() |> Phoenix.HTML.safe_to_string()

  test "reveals <mark> tags around matched terms" do
    assert render("a <mark>widget</mark> here") == "a <mark>widget</mark> here"
  end

  test "HTML in the source is escaped, not rendered" do
    html = render("safe <mark>x</mark> <script>alert(1)</script> & <b>bold</b>")

    # The highlight is the only live markup; everything else is inert text.
    assert html =~ "<mark>x</mark>"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert html =~ "&amp; &lt;b&gt;bold&lt;/b&gt;"
    refute html =~ "<script>"
    refute html =~ "<b>"
  end

  test "blank or nil input renders empty" do
    assert render(nil) == ""
    assert render("") == ""
  end
end
