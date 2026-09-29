defmodule KilnCMS.CMS.Validations.MenuItemPlacement do
  @moduledoc """
  Guards where a menu item may sit: inside its own menu, no deeper than
  `MenuItem.max_depth/0` — **counting the subtree it brings with it** — and
  never inside its own subtree.

  Two things about the shape of this check are load-bearing.

  It only runs when `parent_id` is actually **changing**. A depth check that
  fired on every write would freeze any row that ended up too deep: the editor
  couldn't rename it, and couldn't outdent it either, because outdenting is
  itself a write. Placement is a property of a move, so it is validated on
  moves.

  And a move carries the moving item's children. Checking only the moved node's
  ancestor chain lets an editor re-parent a three-level subtree one level down
  and land its leaves at depth five — accepted at write time, and then
  permanently unmovable. So the check is `ancestors + 1 + subtree height`.

  The cycle check walks *parents*, not descendants: a chain is at most
  `max_depth` long, so it is a bounded handful of point reads. The subtree walk
  is the other direction and is bounded the same way — it stops as soon as it
  has seen more levels than could possibly fit.
  """
  use Ash.Resource.Validation

  require Ash.Query

  alias KilnCMS.CMS.MenuItem
  alias KilnCMS.CMS.Validations.Lookup

  @impl true
  def validate(changeset, _opts, context) do
    if Ash.Changeset.changing_attribute?(changeset, :parent_id) do
      validate_move(changeset, Lookup.as_caller(context, changeset.tenant))
    else
      :ok
    end
  end

  # The walk reads as the caller (#1659). Menu items are world-readable, so an
  # editor moving one sees the whole tree; `authorize_with: :error` still turns
  # a refused read into a Forbidden rejection rather than a subtree read short —
  # which would under-count its height and accept a move that nests too deep.
  defp validate_move(changeset, read_opts) do
    case Ash.Changeset.get_attribute(changeset, :parent_id) do
      nil -> :ok
      parent_id -> validate_parent(changeset, parent_id, read_opts)
    end
  rescue
    forbidden in Ash.Error.Forbidden -> {:error, forbidden}
  end

  defp validate_parent(changeset, parent_id, read_opts) do
    id = Map.get(changeset.data, :id)

    if parent_id == id do
      {:error, field: :parent_id, message: "can't be the item itself"}
    else
      check_ancestry(changeset, parent_id, id, read_opts)
    end
  end

  defp check_ancestry(changeset, parent_id, id, read_opts) do
    case ancestors(read_opts, parent_id) do
      {:error, message} ->
        {:error, field: :parent_id, message: message}

      {:ok, chain} ->
        cond do
          id && id in Enum.map(chain, & &1.id) ->
            {:error, field: :parent_id, message: "can't be one of this item's own children"}

          # `chain` is the new ancestors, `+ 1` is the item itself, and `height`
          # is how many further levels it drags along.
          length(chain) + 1 + height(read_opts, id) > MenuItem.max_depth() ->
            {:error,
             field: :parent_id, message: "would nest deeper than #{MenuItem.max_depth()} levels"}

          different_menu?(changeset, chain) ->
            {:error, field: :parent_id, message: "belongs to a different menu"}

          true ->
            :ok
        end
    end
  end

  # The parent and everything above it, nearest first. Bounded by `max_depth`
  # plus one: a chain longer than that means pre-existing corruption (a cycle
  # committed by two concurrent moves), and walking it forever is exactly what
  # this validation exists to prevent.
  defp ancestors(read_opts, parent_id, acc \\ []) do
    if length(acc) > MenuItem.max_depth() do
      {:error, "is nested too deeply"}
    else
      case fetch(read_opts, parent_id) do
        nil -> {:error, "no longer exists"}
        %{parent_id: nil} = item -> {:ok, Enum.reverse([item | acc])}
        item -> ancestors(read_opts, item.parent_id, [item | acc])
      end
    end
  end

  # Levels of descendants below `id` (0 for a leaf, and for a create — a new
  # item has no children yet). Stops once it has seen more than `max_depth`
  # levels: past that the answer is "too deep" either way, and the bound is what
  # keeps a corrupt cycle from spinning.
  defp height(read_opts, id, level \\ 0)

  defp height(_read_opts, nil, level), do: level

  defp height(read_opts, id, level) do
    if level > MenuItem.max_depth() do
      level
    else
      case child_ids(read_opts, id) do
        [] -> level
        children -> children |> Enum.map(&height(read_opts, &1, level + 1)) |> Enum.max()
      end
    end
  end

  defp fetch(read_opts, id) do
    MenuItem
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id, :parent_id, :menu_id])
    |> Ash.read_one!(read_opts)
  end

  defp child_ids(read_opts, id) do
    MenuItem
    |> Ash.Query.filter(parent_id == ^id)
    |> Ash.Query.select([:id])
    |> Ash.read!(read_opts)
    |> Enum.map(& &1.id)
  end

  defp different_menu?(changeset, chain) do
    menu_id = Ash.Changeset.get_attribute(changeset, :menu_id)
    Enum.any?(chain, &(&1.menu_id != menu_id))
  end
end
