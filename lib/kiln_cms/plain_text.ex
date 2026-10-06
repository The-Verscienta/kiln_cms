defmodule KilnCMS.PlainText do
  @moduledoc """
  Markup to plain text, without a parser and without raising.

  For text that is *read*, not rendered: what search indexes, what an
  embedding model is fed, what an assistant is shown. A parser
  (`Floki.parse_fragment!/1`) raises on markup it cannot read, and a raise
  on a write path fails the editor's save, so this is a pair of regexes
  instead — it never fails, and on input that is not markup at all it
  changes nothing but runs of whitespace.

  It is a reader, not a sanitizer: the text of a `<script>` or `<style>`
  element is kept as text, a `>` inside a quoted attribute ends the tag
  early, and an escaped `&lt;script&gt;` decodes to the literal characters.
  Anything that renders its output as HTML must escape it, as for any text.

  Moved here from `KilnCMS.Assist.Suggestion` so the search index
  (`KilnCMS.CMS.SearchableFields`) strips a custom field's HTML the same way.
  """

  # Named entities, by exact name (`&Delta;` is not `&delta;`). The markup
  # five and `nbsp`, the typographic set a word processor or a rich-text
  # editor emits (dashes, quotes, ellipsis, degree, plus-minus, …), the
  # Latin-1 accented letters, and the Greek alphabet — which is what the text
  # this reads actually contains (constituent names, units, Latin binomials
  # with authorities). An unknown name is left as written.
  @entities Map.merge(
              %{
                "amp" => "&",
                "lt" => "<",
                "gt" => ">",
                "quot" => "\"",
                "apos" => "'",
                "nbsp" => " ",
                "ndash" => "–",
                "mdash" => "—",
                "lsquo" => "‘",
                "rsquo" => "’",
                "sbquo" => "‚",
                "ldquo" => "“",
                "rdquo" => "”",
                "bdquo" => "„",
                "laquo" => "«",
                "raquo" => "»",
                "hellip" => "…",
                "middot" => "·",
                "bull" => "•",
                "prime" => "′",
                "Prime" => "″",
                "deg" => "°",
                "plusmn" => "±",
                "times" => "×",
                "divide" => "÷",
                "minus" => "−",
                "micro" => "µ",
                "le" => "≤",
                "ge" => "≥",
                "ne" => "≠",
                "asymp" => "≈",
                "infin" => "∞",
                "rarr" => "→",
                "larr" => "←",
                "harr" => "↔",
                "uarr" => "↑",
                "darr" => "↓",
                "frac12" => "½",
                "frac14" => "¼",
                "frac34" => "¾",
                "sup1" => "¹",
                "sup2" => "²",
                "sup3" => "³",
                "sect" => "§",
                "para" => "¶",
                "copy" => "©",
                "reg" => "®",
                "trade" => "™",
                "cent" => "¢",
                "pound" => "£",
                "euro" => "€",
                "yen" => "¥",
                "iexcl" => "¡",
                "iquest" => "¿",
                "szlig" => "ß",
                "aelig" => "æ",
                "AElig" => "Æ",
                "oelig" => "œ",
                "OElig" => "Œ",
                "oslash" => "ø",
                "Oslash" => "Ø",
                "aring" => "å",
                "Aring" => "Å",
                "ccedil" => "ç",
                "Ccedil" => "Ç",
                "eth" => "ð",
                "ETH" => "Ð",
                "thorn" => "þ",
                "THORN" => "Þ"
              },
              Map.new(
                for {base, accents} <- [
                      {"a", ~w(acute grave circ uml tilde)},
                      {"e", ~w(acute grave circ uml)},
                      {"i", ~w(acute grave circ uml)},
                      {"o", ~w(acute grave circ uml tilde)},
                      {"u", ~w(acute grave circ uml)},
                      {"y", ~w(acute uml)},
                      {"n", ~w(tilde)}
                    ],
                    accent <- accents,
                    upper? <- [false, true] do
                  letter = if upper?, do: String.upcase(base), else: base

                  mark =
                    %{
                      "acute" => 0x301,
                      "grave" => 0x300,
                      "circ" => 0x302,
                      "uml" => 0x308,
                      "tilde" => 0x303
                    }[accent]

                  {letter <> accent, :unicode.characters_to_nfc_binary(letter <> <<mark::utf8>>)}
                end ++
                  for {name, offset} <-
                        Enum.with_index(
                          ~w(alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu
                             nu xi omicron pi rho sigmaf sigma tau upsilon phi chi psi omega)
                        ),
                      upper? <- [false, true],
                      not (upper? and name == "sigmaf") do
                    # Lower case runs from U+03B1; the capitals sit 0x20 below
                    # (U+03A2, under final sigma, is unassigned).
                    code = 0x3B1 + offset - if(upper?, do: 0x20, else: 0)
                    key = if upper?, do: String.capitalize(name), else: name
                    {key, <<code::utf8>>}
                  end
              )
            )

  # Inline (phrasing) elements: removing one must not split a word or a
  # formula — `C<sub>24</sub>H<sub>30</sub>` is `C24H30`, and
  # `<em>Coptis</em>` next to a parenthesis is `(Coptis)`. Every other tag
  # (a paragraph, a list item, a line break) is a word boundary.
  @inline ~w(a abbr b bdi bdo cite code data dfn em i kbd mark q s samp small span strong sub sup time u var)
  @inline_tag Regex.compile!("</?(?:" <> Enum.join(@inline, "|") <> ")(?:\\s[^>]*)?/?>", "iu")

  @doc """
  `html` as one line of text: tags and comments out, entities decoded,
  whitespace collapsed. `nil` is `""`.

      iex> KilnCMS.PlainText.from_html("<p>Huang Lian (<em>Coptis</em>) &amp; x < y</p>")
      "Huang Lian (Coptis) & x < y"
  """
  @spec from_html(String.t() | nil) :: String.t()
  def from_html(nil), do: ""

  def from_html(html) when is_binary(html) do
    html
    |> strip_tags()
    |> decode_entities()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @doc """
  Removes tags and comments, each replaced with a space.

  Only things that are actually tags — a name or a closing slash after the
  `<`, or a comment. A blanket `<[^>]*>` also eats ordinary prose: "use x < y
  and a > b" came out as "use x b", silently deleting a clause.

  A block tag is replaced with a space, not removed: "one<br>two" must not
  become "onetwo". An inline one (`em`, `strong`, `sub`, `sup`, `span`, `a`,
  …) is removed outright, so it never splits a word: "C<sub>24</sub>" is
  "C24".
  """
  @spec strip_tags(String.t()) :: String.t()
  def strip_tags(text) when is_binary(text) do
    text
    |> String.replace(~r|<!--.*?-->|us, " ")
    |> String.replace(@inline_tag, "")
    |> String.replace(~r|</?[A-Za-z][^>]*>|u, " ")
  end

  @doc """
  Decodes the named entities in `@entities` and every numeric one.

  Decoded, not blanked: substituting a space split the word around them —
  "AT&amp;T and R&amp;D" became "AT T and R D". Run it *after*
  `strip_tags/1`: `&lt;script&gt;` then survives as the literal text
  "<script>" instead of being taken for a tag. An entity this does not know,
  or a numeric one that is not a valid scalar value, is left as written.
  """
  @spec decode_entities(String.t()) :: String.t()
  def decode_entities(text) when is_binary(text) do
    String.replace(text, ~r/&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z]+);/u, fn entity ->
      entity |> String.slice(1..-2//1) |> entity_char() || entity
    end)
  end

  defp entity_char("#x" <> hex), do: codepoint(hex, 16)
  defp entity_char("#X" <> hex), do: codepoint(hex, 16)
  defp entity_char("#" <> digits), do: codepoint(digits, 10)
  # Exact name first (`&Delta;` ≠ `&delta;`); a shouting `&AMP;` still decodes.
  defp entity_char(name),
    do: Map.get(@entities, name) || Map.get(@entities, String.downcase(name))

  defp codepoint(digits, base) do
    case Integer.parse(digits, base) do
      # Valid scalar values only. A surrogate or an out-of-range number would
      # raise in `List.to_string/1`, and a control character is not text.
      {number, ""} when number in 0x20..0xD7FF or number in 0xE000..0x10FFFF ->
        <<number::utf8>>

      _ ->
        nil
    end
  end
end
