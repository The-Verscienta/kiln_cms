defmodule KilnCMS.Blocks.Columns do
  @moduledoc """
  A nested-layout container block (Kiln v2 typed block — D10): the first-party
  answer to visual page building's one genuine gap (#335). Where every other core
  block is a leaf, `columns` holds **child blocks**, turning the otherwise-flat
  block list into a shallow tree.

  Children are stored as raw block maps (jsonb), mirroring the legacy
  `KilnCMS.CMS.Block.children` escape hatch, rather than as a first-class
  `Ash.Type.Union` member. A recursive union member (a block whose field is the
  union that lists it) is a compile-time cycle; keeping children as maps and
  typing them lazily at render time (via `KilnCMS.CMS.TypedBlocks`) sidesteps that
  entirely and keeps the upcaster's "flat documents untouched" guarantee trivial —
  a document with no `columns` block never gains a nesting level.

  Shape (string keys, as stored):

      %{
        "_type" => "columns",
        "layout" => "1-1",                       # width-ratio preset (see @presets)
        "gap" => "md",                           # none | sm | md | lg
        "columns" => [
          %{"blocks" => [<child block map>, ...]},
          %{"blocks" => [<child block map>, ...]}
        ]
      }

  Each child map is the same typed shape as a top-level block (`_type` + attrs),
  so nesting composes: a column may itself contain a `columns` block. Rendering,
  search projection, and reference extraction all recurse through the same typed
  serializers a top-level block uses, so a nested `image`/`rich_text`/`form`
  behaves exactly as it would at the top level.
  """
  use Kiln.Block

  alias KilnCMS.Blocks
  alias KilnCMS.CMS.TypedBlocks

  block :columns do
    # Each entry is a column: `%{"blocks" => [child block maps]}`. Kept as a map
    # array (not a union member) to avoid a recursive-type compile cycle.
    field :columns, {:array, :map}, default: []
    # Width-ratio preset (see @presets); nil renders equal-width columns.
    field :layout, :string
    # Inter-column gap keyword (see @gaps); nil renders the default gap.
    field :gap, :string
  end

  # Width-ratio presets → CSS `grid-template-columns` fractions. The preset is
  # only honoured when its fraction count matches the actual column count;
  # otherwise columns fall back to equal widths, so a layout/columns mismatch
  # never drops or overflows a column.
  @presets %{
    "1-1" => "1fr 1fr",
    "1-2" => "1fr 2fr",
    "2-1" => "2fr 1fr",
    "1-1-1" => "1fr 1fr 1fr",
    "1-2-1" => "1fr 2fr 1fr",
    "1-1-1-1" => "1fr 1fr 1fr 1fr"
  }
  @gaps %{"none" => "0", "sm" => "0.5rem", "md" => "1rem", "lg" => "2rem"}
  @default_gap "1rem"

  @doc "The known width-ratio presets (preset key → fraction string). For the editor."
  @spec presets() :: %{String.t() => String.t()}
  def presets, do: @presets

  @doc """
  The container's inline `style` value for a layout/gap/column-count — the single
  source of grid geometry, shared by this block's `:web` serializer and the live
  delivery renderer (`KilnCMSWeb.BlockComponents`) so both lay columns out the
  same way. Both `layout` and `gap` are resolved through allowlists, so no raw
  user string ever reaches the style (no CSS injection).
  """
  @spec grid_style(String.t() | nil, String.t() | nil, non_neg_integer()) :: String.t()
  def grid_style(layout, gap, count),
    do: "display:grid;grid-template-columns:#{template(layout, count)};gap:#{gap(gap)}"

  # Match a plain variable, not %__MODULE__{} — the block struct is built by an
  # Ash transformer at @before_compile, so it isn't available when these heads
  # compile (a clean compile raises "__struct__/1 is undefined"). KilnCMS.Blocks
  # dispatches by struct type, so the argument is always a columns block.
  @impl Kiln.Block.Renderer
  def render(block, :web) do
    cols = columns(block)

    columns_html =
      Enum.map(cols, fn col ->
        html = col |> child_blocks() |> Enum.map(&Blocks.render(&1, :web))
        ["<div class=\"kiln-column\">", html, "</div>"]
      end)

    style = grid_style(block.layout, block.gap, length(cols))

    ["<div class=\"kiln-columns\" style=\"", esc(style), "\">", columns_html, "</div>"]
  end

  def render(block, :json) do
    %{
      "_type" => "columns",
      "layout" => block.layout,
      "gap" => block.gap,
      "columns" =>
        Enum.map(columns(block), fn col ->
          %{"blocks" => col |> child_blocks() |> Enum.map(&Blocks.render(&1, :json))}
        end)
    }
  end

  # Structural, not a schema.org node of its own — but its children may be. Return
  # the flattened child nodes so nested `image` blocks still contribute to the
  # document @graph (the firing engine flat-maps json_ld results).
  def render(block, :json_ld) do
    block
    |> child_blocks_flat()
    |> Enum.map(&Blocks.render(&1, :json_ld))
    |> Enum.reject(&is_nil/1)
  end

  @impl Kiln.Block.Renderer
  def search_text(block) do
    block
    |> child_blocks_flat()
    |> Enum.map(&Blocks.search_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  @doc "Typed child blocks of every column, flattened in document order."
  @spec child_blocks_flat(struct()) :: [struct()]
  def child_blocks_flat(block) do
    block |> columns() |> Enum.flat_map(&child_blocks/1)
  end

  # Typed child blocks of a single column (tolerates string/atom keys from jsonb).
  defp child_blocks(col), do: col |> raw_blocks() |> TypedBlocks.to_typed()

  defp columns(block), do: block.columns |> List.wrap() |> Enum.filter(&is_map/1)

  defp raw_blocks(col) when is_map(col),
    do: (Map.get(col, "blocks") || Map.get(col, :blocks) || []) |> List.wrap()

  defp raw_blocks(_), do: []

  # `grid-template-columns`: the preset when it matches the column count, else
  # equal widths. `minmax(0, 1fr)` lets columns shrink below their content width
  # (so a long word or wide image can't blow the grid out).
  defp template(layout, count) do
    case Map.get(@presets, layout) do
      fractions when is_binary(fractions) ->
        if length(String.split(fractions, " ")) == count and count > 0,
          do: fractions,
          else: equal(count)

      nil ->
        equal(count)
    end
  end

  defp equal(count) when count > 0, do: "repeat(#{count}, minmax(0, 1fr))"
  defp equal(_), do: "1fr"

  defp gap(keyword), do: Map.get(@gaps, keyword, @default_gap)

  defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
