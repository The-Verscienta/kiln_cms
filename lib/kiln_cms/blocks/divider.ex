defmodule KilnCMS.Blocks.Divider do
  @moduledoc "A horizontal rule / section break (Kiln v2 typed block — D10)."
  use Kiln.Block

  block :divider do
  end

  # Match a plain variable, not %__MODULE__{}: block structs are built by an Ash
  # transformer at @before_compile, so the struct isn't available when these heads
  # compile (a clean compile raises "__struct__/1 is undefined"). KilnCMS.Blocks
  # dispatches by struct type, so the argument is always this block.
  @impl Kiln.Block.Renderer
  def render(_block, :web), do: ["<hr/>"]
  def render(_block, :json), do: %{"_type" => "divider"}
  def render(_block, :json_ld), do: nil

  @impl Kiln.Block.Renderer
  def search_text(_block), do: ""
end
