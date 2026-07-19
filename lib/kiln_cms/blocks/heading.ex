defmodule KilnCMS.Blocks.Heading do
  @moduledoc "A section heading (Kiln v2 typed block — D10)."
  use Kiln.Block

  block :heading do
    version(2)
    field :text, :string, required: true
    field :level, :integer, default: 2

    # v2 made `level` a first-class field; v1 headings stored it (if at all) only
    # in a loose data map. Backfill a sensible default on read (decision D15).
    migrate(from: 1, to: 2, fun: &__MODULE__.upcast_v1_to_v2/1)
  end

  @doc false
  def upcast_v1_to_v2(map), do: Map.put_new(map, "level", 2)

  @impl Kiln.Block.Renderer
  def render(block, :web) do
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

  def render(block, :json),
    do: %{"_type" => "heading", "text" => block.text, "level" => clamp(block.level)}

  # Headings have no standalone schema.org type — they contribute to the document
  # graph (Phase D/J), not a node of their own.
  def render(_block, :json_ld), do: nil

  @impl Kiln.Block.Renderer
  def search_text(block), do: block.text || ""

  # The :llm surface (#357): a real Markdown heading at this block's level —
  # one clamp rule shared with the :web render.
  def to_markdown(block),
    do: String.duplicate("#", clamp(block.level)) <> " " <> (block.text || "")

  defp clamp(level) when level in 1..6, do: level
  defp clamp(_), do: 2

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
