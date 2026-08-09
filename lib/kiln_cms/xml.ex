defmodule KilnCMS.Xml do
  @moduledoc """
  XML text escaping, in one place.

  Three serializers hand-rolled this: the Atom/RSS feeds, the sitemap, and the
  XLIFF exporter (#502). They had already drifted — the sitemap's copy escaped
  three characters where the feed's escaped five and stripped control bytes —
  which is the failure mode a duplicated escaper always has: the copy nobody
  looked at is the one that emits a document no parser will open.

  Two functions, because the two contexts are genuinely different:

    * `escape/1` — element text. `&`, `<`, `>`, `"` and `'` become entities;
      characters XML 1.0 cannot represent at all are dropped, because one stray
      control byte makes the whole document unparseable and losing the byte is
      the smaller failure. A carriage return becomes `&#13;`: XML 1.0 §2.11
      normalizes a literal CR to LF *before* the parser sees it, so a serializer
      that writes one raw does not round-trip.

    * `escape_attribute/1` — attribute values, which get a second normalization
      pass (§3.3.3) that turns every literal tab, newline and carriage return
      into a space. Those three travel as character references instead.
  """

  # Characters XML 1.0 cannot represent. `\\t`, `\\n` and `\\r` are deliberately
  # not in the class — they are legal, and are escaped rather than dropped.
  @illegal ~r/[\x{0000}-\x{0008}\x{000B}\x{000C}\x{000E}-\x{001F}\x{FFFE}\x{FFFF}]/u

  @doc "Escape a value for XML element text."
  @spec escape(term()) :: String.t()
  def escape(value), do: value |> entities() |> String.replace("\r", "&#13;")

  @doc "Escape a value for an XML attribute value (adds tab/newline/CR refs)."
  @spec escape_attribute(term()) :: String.t()
  def escape_attribute(value) do
    value
    |> entities()
    |> String.replace("\r", "&#13;")
    |> String.replace("\n", "&#10;")
    |> String.replace("\t", "&#9;")
  end

  # `"` and `'` are escaped alongside the three that matter in element text so
  # that one function is safe in both contexts — a serializer must not depend on
  # a validation elsewhere staying shaped as it is.
  defp entities(value) do
    value
    |> to_string()
    |> String.replace(@illegal, "")
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
