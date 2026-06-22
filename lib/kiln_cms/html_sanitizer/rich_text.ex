defmodule KilnCMS.HTMLSanitizer.RichText do
  @moduledoc """
  Allowlist for TipTap StarterKit HTML (bold, italic, headings, lists, quotes,
  code, horizontal rules). Everything else — including scripts, iframes, and
  event-handler attributes — is stripped.
  """

  use HtmlSanitizeEx, extend: :strip_tags

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
