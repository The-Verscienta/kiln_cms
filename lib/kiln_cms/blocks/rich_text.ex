defmodule KilnCMS.Blocks.RichText do
  @moduledoc """
  A rich-prose block (Kiln v2 typed block — D10). `body` is canonical Portable
  Text (D12); `legacy_html` is a transitional fallback for content not yet
  migrated off stored TipTap HTML (removed once the Phase C data migration lands).
  """
  use Kiln.Block

  alias KilnCMS.Blocks.PortableText

  block :rich_text do
    field :body, :rich_text, default: []
    field :legacy_html, :string
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

  def render(block, :json),
    do: %{"_type" => "rich_text", "body" => block.body || []}

  def render(_block, :json_ld), do: nil

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
