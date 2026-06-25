defmodule KilnCMS.Blocks.Heading do
  @moduledoc "A section heading (Kiln v2 typed block — D10)."
  use Kiln.Block

  block :heading do
    field :text, :string, required: true
    field :level, :integer, default: 2
  end

  @impl Kiln.Block.Renderer
  def render(%__MODULE__{} = block, :web) do
    level = clamp(block.level)

    [
      "<h",
      Integer.to_string(level),
      ">",
      esc(block.text || ""),
      "</h",
      Integer.to_string(level),
      ">"
    ]
  end

  def render(%__MODULE__{} = block, :json),
    do: %{"_type" => "heading", "text" => block.text, "level" => clamp(block.level)}

  # Headings have no standalone schema.org type — they contribute to the document
  # graph (Phase D/J), not a node of their own.
  def render(%__MODULE__{}, :json_ld), do: nil

  @impl Kiln.Block.Renderer
  def search_text(%__MODULE__{text: text}), do: text || ""

  defp clamp(level) when level in 1..6, do: level
  defp clamp(_), do: 2

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
