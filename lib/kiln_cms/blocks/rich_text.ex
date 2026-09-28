defmodule KilnCMS.Blocks.RichText do
  @moduledoc """
  A rich-prose block (Kiln v2 typed block — D10). `body` is canonical Portable
  Text (D12).

  `legacy_html` holds HTML that Portable Text cannot hold faithfully — marks
  inside a code block, a list inside a quote. 0.12 deprecated it for removal at
  1.0; **1.0 keeps it as a fallback instead** (#1543), because for exactly
  those blocks it is the only faithful copy of the author's prose, and removing
  the field would have dropped it:

    * `mix kiln.blocks.backfill` converts `legacy_html` to `body` wherever that
      is faithful, and keeps and reports it where it is not;
    * no editor writes to it when Portable Text can hold the prose — the
      canvas, the nested column editor and the inline editor all store `body`;
    * it renders (sanitized) only when `body` is empty.

  Read `body` first, and write `body` wherever Portable Text can hold the prose.
  The exported block schema keeps the property `deprecated`: a later major may
  remove it once a converter can hold what it keeps. (The docs publisher,
  `scripts/publish_docs.exs`, writes rendered guides here, since their code
  blocks are exactly what Portable Text cannot hold.)
  """
  use Kiln.Block

  alias KilnCMS.Blocks.PortableText

  block :rich_text do
    field :body, :rich_text, default: []
    # Transitional stored TipTap HTML. Not translatable *as HTML* (#502): a
    # vendor editing raw markup writes broken tags back. The XLIFF exporter
    # instead converts it through `PortableText.from_html/1` and cuts the
    # result into ordinary `body` units (#1106) — the translation comes back
    # as Portable Text in `body`, and this field is what `:unsupported` still
    # reports only when that conversion yields no prose at all.
    field :legacy_html, :string, translatable: :unsupported
  end

  @impl Kiln.Block.Renderer
  def render(block, :web) do
    case block.body do
      [_ | _] = body ->
        PortableText.to_html(body)

      _ ->
        # Legacy stored TipTap HTML is untrusted: strip it to the allowlist before
        # it reaches a fired `:web` artifact (headless consumers assign to innerHTML).
        KilnCMS.HTMLSanitizer.sanitize_rich_text(block.legacy_html)
    end
  end

  def render(block, :json) do
    case block.body do
      [_ | _] = body ->
        %{"_type" => "rich_text", "body" => body}

      _ ->
        # TipTap-authored prose is stored in legacy_html until the PT round-trip
        # ships; without this fallback the json artifact carried `body: []` and
        # headless consumers silently lost the text. Sanitized, same as :web.
        %{
          "_type" => "rich_text",
          "body" => [],
          "legacy_html" => KilnCMS.HTMLSanitizer.sanitize_rich_text(block.legacy_html)
        }
    end
  end

  def render(_block, :json_ld), do: nil

  # Both render branches emit `body` as a real array (the fallback emits `[]`
  # alongside the sanitized HTML), so it is required and never null.
  #
  # `legacy_html` carries the JSON Schema `deprecated` keyword (#1537), which is
  # how the marker reaches a typed client's generated code rather than only this
  # changelog. It stays in the schema because the
  # `:json` artifact still emits it for a block whose `body` is empty.
  @impl Kiln.Block.Renderer
  def json_schema do
    %{
      "required" => ["_type", "body"],
      "properties" => %{
        "body" => Kiln.Block.JsonSchema.type_schema(:rich_text, false),
        "legacy_html" =>
          :string
          |> Kiln.Block.JsonSchema.type_schema()
          |> Map.merge(%{
            "deprecated" => true,
            "description" =>
              "Sanitized HTML that Portable Text cannot hold faithfully, present only " <>
                "when `body` is empty. Read `body` first, and write `body` wherever it can hold the prose."
          })
      }
    }
  end

  @impl Kiln.Block.Renderer
  def search_text(block) do
    case block.body do
      [_ | _] = body -> PortableText.to_plain_text(body)
      _ -> strip(block.legacy_html)
    end
  end

  defp strip(nil), do: ""

  defp strip(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
