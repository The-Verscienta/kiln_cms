defmodule KilnCMS.HTMLSanitizer.RichText do
  @moduledoc """
  Allowlist for TipTap StarterKit HTML (bold, italic, headings, lists, quotes,
  code, horizontal rules) plus safe hyperlinks. Everything else — including
  scripts, iframes, and event-handler attributes — is stripped.

  Shared by both public HTML delivery (`BlockComponents`) and the fired headless
  `:web` artifacts (`RichText.render(:web)`), so the link allowlist here is the
  single source of truth for what survives to readers (#148).
  """

  use HtmlSanitizeEx, extend: :strip_tags

  # Safe hyperlinks (#148): `<a href>` for `https:` / `mailto:` and relative URLs
  # (schemeless hrefs like `/blog/x` or `#anchor` are kept). `javascript:`,
  # `data:`, and bare `http:` schemes are rejected by the scheme allowlist;
  # `target`/`rel`/event-handler attributes are scrubbed off.
  allow_tag_with_uri_attributes("a", ["href"], ["https", "mailto"])

  allow_tag_with_these_attributes("p", [])
  allow_tag_with_these_attributes("br", [])
  allow_tag_with_these_attributes("hr", [])
  allow_tag_with_these_attributes("strong", [])
  allow_tag_with_these_attributes("b", [])
  allow_tag_with_these_attributes("em", [])
  allow_tag_with_these_attributes("i", [])
  allow_tag_with_these_attributes("s", [])
  allow_tag_with_these_attributes("strike", [])
  # Highlighted code blocks (#503): fired PT→HTML re-enters this allowlist on
  # the first-party delivery path (BlockComponents), so the exact markup Makeup
  # emits must survive — `<pre class="highlight">`, `<code class="language-…">`,
  # and token `<span>`s whose class comes from Makeup's finite token-class set.
  # Classes are matched against those closed sets; any other value is stripped,
  # so arbitrary utility classes still can't be smuggled into rich text.
  @makeup_span_classes KilnCMS.Highlight.span_classes()

  allow_tag_with_these_attributes "code", [] do
    {"class", "language-" <> language} ->
      if KilnCMS.Highlight.normalize(language) == language,
        do: {"class", "language-" <> language}
  end

  allow_tag_with_these_attributes "pre", [] do
    {"class", "highlight"} -> {"class", "highlight"}
  end

  allow_tag_with_these_attributes "span", [] do
    {"class", value} -> if value in @makeup_span_classes, do: {"class", value}
  end

  allow_tag_with_these_attributes("h1", [])
  allow_tag_with_these_attributes("h2", [])
  allow_tag_with_these_attributes("h3", [])
  allow_tag_with_these_attributes("h4", [])
  allow_tag_with_these_attributes("h5", [])
  allow_tag_with_these_attributes("h6", [])
  allow_tag_with_these_attributes("ul", [])
  allow_tag_with_these_attributes("ol", [])
  allow_tag_with_these_attributes("li", [])
  allow_tag_with_these_attributes("blockquote", [])

  # Tables (#475): the accessible markup the PT renderer emits — th scope
  # col/row, and digit-only col/rowspan (capped length; "0" is invalid HTML
  # anyway and 4 digits is beyond any real table).
  allow_tag_with_these_attributes("table", [])
  allow_tag_with_these_attributes("thead", [])
  allow_tag_with_these_attributes("tbody", [])
  allow_tag_with_these_attributes("tr", [])

  allow_tag_with_these_attributes "th", [] do
    {"scope", scope} when scope in ["col", "row"] -> {"scope", scope}
    {attr, value} when attr in ["colspan", "rowspan"] -> valid_span(attr, value)
  end

  allow_tag_with_these_attributes "td", [] do
    {attr, value} when attr in ["colspan", "rowspan"] -> valid_span(attr, value)
  end

  defp valid_span(attr, value) do
    if value =~ ~r/^[1-9][0-9]{0,3}$/, do: {attr, value}
  end
end
