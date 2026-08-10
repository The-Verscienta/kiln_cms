defmodule KilnCMS.CMS.Calculations.BlockIds do
  @moduledoc """
  The block tree projected to **identity only** (#954): each block as
  `%{"_id" => id, "_type" => type}`, nested `columns` children included in the
  positions they render, and nothing else.

  This is the read surface that makes the `EnforceBlockFieldPolicy` #865
  binding satisfiable by every client. The binding requires a restricted
  nested value to come back under the child id that held it, and `_id` is
  accepted on the write path (`KilnCMS.CMS.TypedBlocks`) — but until this
  calculation existed a **draft's** ids were unreadable: `blocks` is not
  `public?`, GraphQL hides it, and the fired `:json` artifact (the one surface
  that emits `_id`) exists only for published content. A rule that demands ids
  back is only fair once every legitimate caller can read them; this is what
  closes that gap.

  ## What it deliberately is not

  Not a widening of `blocks`. The tree carries every field of every block,
  including ones behind `editable_by`, and it is non-`public?` on purpose —
  this projection carries **no field values**, only `_id`/`_type` and the
  column structure (position is what lets a client tell which id names which
  child). A stored block or child with no id contributes no `"_id"` key rather
  than a minted one: reads never invent identity, and the policy's strictness
  is keyed on ids that are actually stored.

  ## Who can read it

  Whoever can read the row — the calculation adds no grant of its own. Drafts
  are readable only through `Checks.ReadableContentType` (editor tier) or the
  admin bypass, so a draft's ids are editor-scoped like the rest of the
  authoring surface. On a published row the same ids are already public in the
  fired artifact's `_id`, so delivery reads gain nothing they did not have.

  The `_id` spelling matches the artifact's, so a client round-trips either
  surface the same way: read, edit permitted fields, send back.
  """
  use Ash.Resource.Calculation

  alias KilnCMS.Blocks.Columns

  @impl true
  def load(_query, _opts, _context), do: [:blocks]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      record.blocks |> List.wrap() |> Enum.map(&project/1)
    end)
  end

  defp project(%Ash.Union{value: value}), do: project(value)

  defp project(%Columns{} = block),
    do: block |> identity_map() |> Map.put("columns", Columns.child_id_columns(block))

  defp project(%_{} = block), do: identity_map(block)
  defp project(_other), do: %{}

  defp identity_map(%_{} = block) do
    base =
      case Map.get(block, :_type) do
        type when is_binary(type) -> %{"_type" => type}
        _none -> %{}
      end

    case Map.get(block, :id) do
      id when is_binary(id) and id != "" -> Map.put(base, "_id", id)
      _none -> base
    end
  end
end
