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
  allow_tag_with_these_attributes("code", [])
  allow_tag_with_these_attributes("pre", [])
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
end
