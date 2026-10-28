defmodule KilnCMS.CMS.TextFormat do
  @moduledoc """
  What a **rich** `:text` custom field (`FieldDefinition.format == :rich`, the
  default) does with its value: the content editor edits it with TipTap, and
  `Changes.ApplyCustomFields` sanitizes it on write to the rich-text block's
  allow-list (`KilnCMS.HTMLSanitizer.RichText`).

  Two kinds of stored value are left exactly as they are, because they are
  not HTML anyone wrote:

    * **JSON data** — a list or an object stored as text, the shape importers
      used before `:group` and multiple `:select` existed
      (docs/field-conversion.md). Sanitizing would entity-encode its quotes,
      and TipTap would wrap it in a paragraph; either breaks every reader of
      it. The editor shows such a value in the plain textarea instead
      (`json_data?/1`).
    * **text with no markup** — nothing a sanitizer removes can be in it, and
      running it through one would still re-encode its `&` and quotes.

  Everything else is markup. When the sanitizer removed nothing — its output
  parses to the same tree as the input — the value is kept **byte for byte**:
  the sanitizer also normalizes what it keeps (`&mdash;` becomes `—`, quotes
  and attribute order change), and an editor's save of some other field must
  not rewrite an importer's HTML that was safe all along. Otherwise the
  sanitized markup is stored.
  """

  alias KilnCMS.HTMLSanitizer

  @doc "The value a rich `:text` field stores for `text`."
  @spec sanitize(String.t()) :: String.t()
  def sanitize(text) when is_binary(text) do
    cond do
      not String.contains?(text, "<") -> text
      json_data?(text) -> text
      true -> text |> HTMLSanitizer.sanitize_rich_text() |> keep_if_unchanged(text)
    end
  end

  defp keep_if_unchanged(sanitized, text) do
    if same_tree?(sanitized, text), do: text, else: sanitized
  end

  defp same_tree?(a, b) do
    with {:ok, tree_a} <- Floki.parse_fragment(a),
         {:ok, tree_b} <- Floki.parse_fragment(b) do
      normalize(tree_a) == normalize(tree_b)
    else
      _error -> false
    end
  end

  # Attribute order is not content.
  defp normalize(nodes) when is_list(nodes), do: Enum.map(nodes, &normalize/1)

  defp normalize({tag, attrs, children}),
    do: {tag, Enum.sort(attrs), normalize(children)}

  defp normalize(other), do: other

  @doc """
  Whether `value` is a JSON list or object stored as text — data, not prose,
  so neither TipTap nor the sanitizer may touch it.
  """
  @spec json_data?(term()) :: boolean()
  def json_data?(value) when is_binary(value) do
    case String.trim_leading(value) do
      <<c, _::binary>> when c in [?[, ?{] ->
        match?({:ok, decoded} when is_list(decoded) or is_map(decoded), Jason.decode(value))

      _other ->
        false
    end
  end

  def json_data?(_value), do: false
end
