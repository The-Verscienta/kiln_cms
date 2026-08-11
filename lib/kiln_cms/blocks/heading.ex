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

  # The rendered heading level, and the one place its bounds are stated: both
  # `clamp/1` and the exported schema read these.
  @min_level 1
  @max_level 6
  @default_level 2

  @doc false
  def upcast_v1_to_v2(map), do: Map.put_new(map, "level", @default_level)

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

  # `level` is clamped on render, so the delivery value is always in range — and
  # never null, which the derived schema could not know. Bounds come from the
  # same constants `clamp/1` uses, so widening the clamp cannot leave the
  # published schema behind.
  @impl Kiln.Block.Renderer
  def json_schema do
    %{
      "properties" => %{
        "level" => %{
          "type" => "integer",
          "minimum" => @min_level,
          "maximum" => @max_level,
          "default" => @default_level
        }
      }
    }
  end

  @impl Kiln.Block.Renderer
  def search_text(block), do: block.text || ""

  # The :llm surface (#357): a real Markdown heading at this block's level —
  # one clamp rule shared with the :web render.
  def to_markdown(block),
    do: String.duplicate("#", clamp(block.level)) <> " " <> (block.text || "")

  # `is_integer` is load-bearing: `level in @min_level..@max_level` implied it,
  # a bare comparison does not. Without it a stored `2.5` passes both bounds and
  # renders `<h2.5>`, and `nil` sorts above every number in term order.
  defp clamp(level) when is_integer(level) and level >= @min_level and level <= @max_level,
    do: level

  defp clamp(_), do: @default_level

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
