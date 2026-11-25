defmodule KilnCMS.Firing.AnswerText do
  @moduledoc """
  The text of the custom fields an admin opted into the AI-readable fired
  artifacts (`FieldDefinition.deliver_llm`, #2282, ADR 0082): the `:llm`
  Markdown (`KilnCMS.Firing.LlmMarkdown`) and the `:json_ld` `hasPart`
  elements (`KilnCMS.Firing.Engine`).

  `entries/1` walks the resolved custom fields (`KilnCMS.Firing.CustomFields`:
  private values already dropped, unreadable reference snapshots masked) once,
  and returns one neutral entry per flagged top-level field, in position order:

      %{label: "FAQ", kind: :flexible, parts: [{:item, item}, …]}
      item = %{label: "Question", parts: [{:text, "Answer", "…"}, {:item, nested}]}

    * `:text` (a `:string` or `:text` field): `parts` is one
      `{:text, field_label, text}`; a rich `:text` field's HTML is plain text
      with paragraph breaks (`KilnCMS.PlainText`);
    * `:group`: one `{:text, sub_field_label, text}` per text sub-field of
      each row;
    * `:flexible`: one `{:item, item}` per item, whose parts are its text
      sub-fields and, for a nested `:flexible` sub-field, its own items.

  Both surfaces render from the same entries, so they cannot disagree about
  what a document says. Only text counts: numbers, media, references, enums
  and the like are not projected, nor is a sub-field flagged `item_setting`
  (presentation). Every text sub-field of a flagged container is included,
  and so goes public with it. An item whose `_type` has no definition, and a
  key no definition names, are ignored — never printed raw. Empty values
  contribute nothing, and neither does a field left with no text.

  The caps are `max_elements/0` `:json_ld` elements and `max_chars/0`
  characters per element or `:llm` section, cut at a word boundary with `…`.
  """

  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.PlainText

  @max_elements 50
  @max_chars 5_000
  @text_types [:string, :text]

  @type part :: {:text, String.t(), String.t()} | {:item, item()}
  @type item :: %{label: String.t(), parts: [part()]}
  @type entry :: %{label: String.t(), kind: :text | :group | :flexible, parts: [part()]}

  @doc "The most `hasPart` elements a fired `:json_ld` artifact carries."
  @spec max_elements() :: pos_integer()
  def max_elements, do: @max_elements

  @doc "The most characters one `hasPart` element's text, or one `:llm` section, carries."
  @spec max_chars() :: pos_integer()
  def max_chars, do: @max_chars

  @doc """
  The opted-in fields' text for a resolved `KilnCMS.Firing.CustomFields`
  result (`nil` and a result without definitions give `[]`).
  """
  @spec entries(map() | nil) :: [entry()]
  def entries(%{values: values, definitions: definitions}) when is_map(values) do
    definitions
    |> Enum.filter(&flagged?/1)
    |> Enum.sort_by(&{&1.position, &1.name})
    |> Enum.flat_map(&entry(&1, Map.get(values, &1.name)))
  end

  def entries(_custom), do: []

  # Only a top-level row is a field of the type: a nested row's flag, were one
  # ever stored, is ignored (`Changes.ClearDeliverLlm` clears it).
  defp flagged?(definition) do
    Map.get(definition, :deliver_llm) == true and not Map.get(definition, :private, false) and
      FieldDefinition.top_level?(definition) and
      definition.field_type in [:string, :text, :group, :flexible]
  end

  defp entry(%{field_type: type} = definition, value) when type in @text_types do
    case texts(definition, value) do
      [] ->
        []

      texts ->
        [
          %{
            label: label(definition),
            kind: :text,
            parts: [{:text, label(definition), Enum.join(texts, "\n\n")}]
          }
        ]
    end
  end

  defp entry(%{field_type: :group} = definition, value) do
    parts =
      value
      |> rows()
      |> Enum.flat_map(&sub_parts(FieldDefinition.group_fields(definition), &1, 1))

    present(definition, :group, parts)
  end

  defp entry(%{field_type: :flexible} = definition, value),
    do: present(definition, :flexible, items(definition, value, 1))

  defp present(_definition, _kind, []), do: []

  defp present(definition, kind, parts),
    do: [%{label: label(definition), kind: kind, parts: parts}]

  defp rows(%{} = row), do: [row]
  defp rows(rows) when is_list(rows), do: Enum.filter(rows, &is_map/1)
  defp rows(_other), do: []

  defp items(definition, value, depth) when depth <= 3 do
    types = Map.new(FieldDefinition.item_types(definition), &{&1.name, &1})

    for %{} = item <- List.wrap(value),
        %{} = type <- [Map.get(types, item["_type"])],
        part <- item_part(type, item, depth),
        do: part
  end

  defp items(_definition, _value, _depth), do: []

  defp item_part(type, item, depth) do
    case sub_parts(FieldDefinition.group_fields(type), item, depth) do
      [] -> []
      parts -> [{:item, %{label: label(type), parts: parts}}]
    end
  end

  defp sub_parts(sub_fields, row, depth) do
    sub_fields
    |> Enum.reject(& &1.item_setting)
    |> Enum.sort_by(&{&1.position, &1.name})
    |> Enum.flat_map(&sub_part(&1, Map.get(row, &1.name), depth))
  end

  defp sub_part(%{field_type: type} = sub, value, _depth) when type in @text_types do
    case texts(sub, value) do
      [] -> []
      texts -> [{:text, label(sub), Enum.join(texts, "\n\n")}]
    end
  end

  defp sub_part(%{field_type: :flexible} = sub, value, depth),
    do: items(sub, value, depth + 1)

  defp sub_part(_sub, _value, _depth), do: []

  defp texts(definition, value) do
    value
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&plain(definition, &1))
    |> Enum.reject(&(&1 == ""))
  end

  defp plain(%{field_type: :text, format: :rich}, html),
    do: html |> PlainText.from_html_paragraphs() |> String.trim()

  defp plain(_definition, text), do: String.trim(text)

  defp label(%{label: label}) when is_binary(label), do: label |> String.split() |> Enum.join(" ")
  defp label(%{name: name}), do: to_string(name)

  # --- renderers -----------------------------------------------------------------

  @doc """
  The `:llm` Markdown sections of `entries`, one per field: `## label`, then
  the text (`:text`), or one `**label:** text` paragraph per sub-field (`:group`,
  and each item under a `###` heading, deeper for nested items, `######` at
  most). Each section is capped at `max_chars/0`.
  """
  @spec markdown([entry()]) :: [String.t()]
  def markdown(entries) do
    Enum.map(entries, fn %{label: label, kind: kind, parts: parts} ->
      body = parts |> markdown_parts(kind, 3) |> Enum.join("\n\n") |> truncate()
      "## " <> label <> "\n\n" <> body
    end)
  end

  defp markdown_parts(parts, :text, _level), do: for({:text, _label, text} <- parts, do: text)

  defp markdown_parts(parts, _kind, level) do
    Enum.flat_map(parts, fn
      {:text, label, text} ->
        ["**#{label}:** #{text}"]

      {:item, %{label: label, parts: sub}} ->
        [
          String.duplicate("#", min(level, 6)) <> " " <> label
          | markdown_parts(sub, :item, level + 1)
        ]
    end)
  end

  @doc """
  The `WebPageElement` nodes of `entries` for the `:json_ld` main node's
  `hasPart`: one per `:text` or `:group` field (named by its label) and one
  per top-level flexible item (named by its item type's label, nested items'
  text flattened into it). At most `max_elements/0`, each text capped at
  `max_chars/0`.
  """
  @spec web_page_elements([entry()]) :: [map()]
  def web_page_elements(entries) do
    entries
    |> Enum.flat_map(&elements/1)
    |> Enum.take(@max_elements)
  end

  defp elements(%{kind: :flexible, parts: parts}) do
    for {:item, %{label: label, parts: sub}} <- parts, do: element(label, sub)
  end

  defp elements(%{label: label, parts: parts}), do: [element(label, parts)]

  defp element(name, parts) do
    %{
      "@type" => "WebPageElement",
      "name" => name,
      "text" => parts |> flat_texts() |> Enum.join("\n\n") |> truncate()
    }
  end

  defp flat_texts(parts) do
    Enum.flat_map(parts, fn
      {:text, _label, text} -> [text]
      {:item, %{parts: sub}} -> flat_texts(sub)
    end)
  end

  defp truncate(text) when byte_size(text) <= @max_chars, do: text

  defp truncate(text) do
    if String.length(text) <= @max_chars do
      text
    else
      cut = String.slice(text, 0, @max_chars)

      # Mid-word: back up to the last space. A cut that lands on one keeps all.
      cut =
        with false <- String.match?(String.at(text, @max_chars), ~r/\s/u),
             [_, head] <- Regex.run(~r/^(.*\S)\s+\S*$/su, cut) do
          head
        else
          _boundary_or_single_word -> cut
        end

      String.trim_trailing(cut) <> "…"
    end
  end
end
