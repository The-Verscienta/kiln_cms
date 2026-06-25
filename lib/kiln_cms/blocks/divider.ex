defmodule KilnCMS.Blocks.Divider do
  @moduledoc "A horizontal rule / section break (Kiln v2 typed block — D10)."
  use Kiln.Block

  block :divider do
  end

  @impl Kiln.Block.Renderer
  def render(%__MODULE__{}, :web), do: ["<hr/>"]
  def render(%__MODULE__{}, :json), do: %{"_type" => "divider"}
  def render(%__MODULE__{}, :json_ld), do: nil

  @impl Kiln.Block.Renderer
  def search_text(%__MODULE__{}), do: ""
end
