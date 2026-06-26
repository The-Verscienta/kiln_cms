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
  def render(%__MODULE__{body: [_ | _] = body}, :web), do: PortableText.to_html(body)
  def render(%__MODULE__{legacy_html: legacy}, :web), do: legacy || ""

  def render(%__MODULE__{} = block, :json),
    do: %{"_type" => "rich_text", "body" => block.body || []}

  def render(%__MODULE__{}, :json_ld), do: nil

  @impl Kiln.Block.Renderer
  def search_text(%__MODULE__{body: [_ | _] = body}), do: PortableText.to_plain_text(body)
  def search_text(%__MODULE__{legacy_html: legacy}), do: strip(legacy)

  defp strip(nil), do: ""

  defp strip(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
