defmodule KilnCMS.CMS.PortableFields do
  @moduledoc """
  The Portable Text rendition of a record's rich `:text` custom fields that
  opt in with `deliver_portable` (`KilnCMS.CMS.FieldDefinition`).

  A rich `:text` field (`format: :rich`, the default) stores sanitized HTML
  (`KilnCMS.CMS.TextFormat`), and delivery passes it through untouched. A web
  client renders that; a native app has to run a browser engine to show it,
  or settle for `custom_fields_plain` (`KilnCMS.CMS.PlainFields`), which
  keeps the words and loses the paragraphs, marks, links and lists. So
  delivery carries a sibling map, `custom_fields_portable`, holding each
  flagged field's value as Portable Text — the same tree the `rich_text`
  block's `body` delivers, so an app that renders a body renders a field
  with the same code — beside `custom_fields`, which is never rewritten.

  ## The conversion

  `KilnCMS.Blocks.PortableText.from_html/1`, the converter the `rich_text`
  block's `legacy_html` migration uses, after the rich-text sanitizer and
  followed by `PortableText.sanitize_body/1`. Not `from_html_faithful/1`:
  that one is a gate for *rewriting* stored prose, and refuses whatever it
  would lose. A delivered rendition must always be there, and the stored HTML
  stays beside it in `custom_fields`, so the few things `from_html/1` drops
  (an `<img>` inside prose, an unknown element's wrapper) cost a native
  reader nothing it could have shown. The sanitizer runs first because a
  value stored before `:text` became rich (#2099) has not been through it.

  A value with no markup at all — text typed into the plain textarea before
  #2099, or by an importer — is read as text, not HTML: a blank line starts
  a paragraph and a single newline is a line break, as the textarea showed
  it. A JSON list or object stored as text (`TextFormat.json_data?/1`) is
  data, not prose, and has no rendition: `nil`.

  One rule, three surfaces: the fired `:json` artifact
  (`KilnCMS.Firing.Engine`, so `/api/content` and `/api/sync`), the
  `custom_fields_portable` calculation (JSON:API and GraphQL, on request),
  and the schema (`KilnCMS.SchemaExport`, by `$ref` to the shared
  `portable_text_block`).

  Every flagged field has a key, `nil` when the record holds no string for
  it (or holds data), so a client reads one shape per type. A blank value is
  `[]`.

  Group sub-fields are out of scope: a group's rows are delivered whole
  inside `custom_fields.<group>`, and a sub-field cannot set the flag
  (`Changes.ClearDeliverPortable`).
  """

  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.CMS.TextFormat

  @doc "The names of the fields among `definitions` that deliver a Portable Text rendition."
  @spec names([KilnCMS.CMS.FieldDefinition.t()]) :: [String.t()]
  def names(definitions) do
    for %{deliver_portable: true, field_type: :text} = definition <- definitions,
        Map.get(definition, :format, :rich) == :rich,
        is_nil(Map.get(definition, :link_of_id)),
        is_nil(Map.get(definition, :group_of_id)),
        do: definition.name
  end

  @doc """
  The `custom_fields_portable` map for `values` under `definitions`, or `nil`
  when no definition opts in — the caller leaves the key out then.

      iex> defs = [%{name: "body", field_type: :text, deliver_portable: true}]
      iex> KilnCMS.CMS.PortableFields.project(%{"body" => "<p>A &amp; <em>B</em></p>"}, defs)
      %{
        "body" => [
          %{
            "_key" => "b0",
            "_type" => "block",
            "children" => [
              %{"_type" => "span", "marks" => [], "text" => "A & "},
              %{"_type" => "span", "marks" => ["em"], "text" => "B"}
            ],
            "markDefs" => [],
            "style" => "normal"
          }
        ]
      }
      iex> KilnCMS.CMS.PortableFields.project(%{}, defs)
      %{"body" => nil}
      iex> KilnCMS.CMS.PortableFields.project(%{"body" => "x"}, [])
      nil
  """
  @spec project(map() | nil, [KilnCMS.CMS.FieldDefinition.t()]) :: map() | nil
  def project(values, definitions) do
    case names(definitions) do
      [] -> nil
      names -> Map.new(names, &{&1, portable(Map.get(values || %{}, &1))})
    end
  end

  @doc """
  The Portable Text rendition of one stored rich `:text` value, or `nil` for
  one that is not text, or is JSON data.
  """
  @spec portable(term()) :: [PortableText.pt_block()] | nil
  def portable(value) when is_binary(value) do
    cond do
      TextFormat.json_data?(value) -> nil
      String.contains?(value, "<") -> from_markup(value)
      true -> from_text(value)
    end
  end

  def portable(_value), do: nil

  defp from_markup(html) do
    html
    |> KilnCMS.HTMLSanitizer.sanitize_rich_text()
    |> PortableText.from_html()
    |> PortableText.sanitize_body()
  end

  # Markup-free text: escaped and shaped into the paragraphs and line breaks
  # it was typed with, then converted like any other HTML, so the blocks and
  # keys are the ones the same paragraphs written in the editor would get.
  defp from_text(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join(fn paragraph ->
      lines = paragraph |> String.split("\n") |> Enum.map(&escape/1)
      "<p>" <> Enum.join(lines, "<br>") <> "</p>"
    end)
    |> PortableText.from_html()
  end

  defp escape(text),
    do: text |> String.trim() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
