defmodule KilnCMS.Blocks.Custom do
  @moduledoc """
  Catch-all typed block (Kiln v2 — D10). Carries any legacy/unmapped block
  (`divider`, `columns`, `custom`, or future unknowns) so the typed system and
  every serializer stay **total** over all content (decision A4). `legacy_type`
  preserves the original discriminator; `content`/`data` preserve the payload.
  """
  use Kiln.Block

  block :custom do
    field :legacy_type, :string
    field :content, :string
    field :data, :map, default: %{}
  end

  @impl Kiln.Block.Renderer
  def render(%__MODULE__{legacy_type: "divider"}, :web), do: ["<hr/>"]

  def render(%__MODULE__{} = block, :web) do
    ["<!-- ", esc(block.legacy_type || "custom"), " block -->"]
  end

  def render(%__MODULE__{} = block, :json) do
    %{
      "_type" => "custom",
      "legacy_type" => block.legacy_type,
      "content" => block.content,
      "data" => block.data || %{}
    }
  end

  def render(%__MODULE__{}, :json_ld), do: nil

  @impl Kiln.Block.Renderer
  def search_text(%__MODULE__{content: content}) when is_binary(content),
    do:
      content |> String.replace(~r/<[^>]*>/, " ") |> String.replace(~r/\s+/, " ") |> String.trim()

  def search_text(%__MODULE__{}), do: ""

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
