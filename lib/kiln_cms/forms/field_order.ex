defmodule KilnCMS.Forms.FieldOrder do
  @moduledoc """
  Saving a form's field order (#2717): the builder's drag-and-drop and the
  slot a duplicated field takes after its original.

  One transaction. The builder used to write one `position` per moved field
  and discard every result, so a refused write left a half-applied order on
  the page and in the database, with no message. Now the first refused write
  rolls back every position before it, and the caller learns which field was
  refused and why.

  A position-only update still runs every `FormField` validation, so a row an
  older release let through — a dropdown saved without options, say — refuses
  the whole reorder until it is fixed. That is the point: a half-saved order
  is worse than none, and the refusal names the field to fix.

  The writes run through `CMS.update_form_field/3` as the acting user, so the
  ordinary policies apply (admin-only, like every `FormField` write).

  Conditions (#2262) name only earlier fields, so the final order is checked
  once before anything moves (`KilnCMS.Forms.Logic.order_violations/1`): an
  order that would put a field before one its condition names is refused
  whole, naming both. Only a break the new order introduces counts, so a rule
  an older release let fall out of order doesn't block every reorder. The
  moves then carry `form_field_reorder: true`, which spares each one the
  per-row order check: the order between two moves means nothing.
  """

  alias KilnCMS.AfterCommit
  alias KilnCMS.CMS
  alias KilnCMS.CMS.FormField
  alias KilnCMS.Forms.Logic

  @doc """
  Give each field in `order` (a list of field ids) its index as its
  `position`. Ids not among `fields` are ignored, and a field already at its
  index is not written.

  Returns `:ok`, `{:error, {:field, field, error}}` when `field`'s write was
  refused, `{:error, {:conditions, field, target}}` when the order would put
  `field` before `target`, which its condition names (nothing was moved
  either way), or `{:error, error}` when the transaction failed some other
  way. `opts` are the usual `:actor` / `:tenant`.
  """
  @spec reorder([FormField.t()], [String.t()], keyword()) ::
          :ok
          | {:error, {:field, FormField.t(), term()}}
          | {:error, {:conditions, FormField.t(), FormField.t()}}
          | {:error, term()}
  def reorder(fields, order, opts) when is_list(fields) and is_list(order) do
    fields_by_id = Map.new(fields, &{&1.id, &1})

    moves =
      order
      |> Enum.with_index()
      |> Enum.flat_map(fn {id, index} ->
        case fields_by_id[id] do
          %FormField{position: position} = field when position != index -> [{field, index}]
          _unknown_or_in_place -> []
        end
      end)

    case new_violations(fields, moves) do
      [] -> run(moves, opts)
      [{field, target} | _rest] -> {:error, {:conditions, field, target}}
    end
  end

  defp new_violations(_fields, []), do: []

  defp new_violations(fields, moves) do
    moved = Map.new(moves, fn {field, index} -> {field.id, index} end)
    before = Logic.sort(fields)

    after_moves =
      fields |> Enum.map(&%{&1 | position: Map.get(moved, &1.id, &1.position)}) |> Logic.sort()

    seen = before |> Logic.order_violations() |> MapSet.new(fn {f, t} -> {f.id, t.id} end)

    after_moves
    |> Logic.order_violations()
    |> Enum.reject(fn {f, t} -> MapSet.member?(seen, {f.id, t.id}) end)
  end

  defp run([], _opts), do: :ok

  defp run(moves, opts) do
    opts =
      opts
      |> with_after_commit_context()
      |> Keyword.update!(:context, &Map.put(&1, :form_field_reorder, true))

    # `Ash.transact/3` turns whatever the function returns as `{:error, _}`
    # into an Ash error class, which would lose *which* field was refused. A
    # refused write leaves the function as a throw instead: the transaction
    # rolls back on it as on any exception, and it is caught just outside.
    result =
      AfterCommit.deferring(fn ->
        Ash.transact([FormField], fn -> move_all!(moves, opts) end)
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  catch
    {__MODULE__, field, error} -> {:error, {:field, field, error}}
  end

  defp move_all!(moves, opts),
    do: Enum.each(moves, fn {field, index} -> move!(field, index, opts) end)

  defp move!(field, index, opts) do
    case CMS.update_form_field(field, %{position: index}, opts) do
      {:ok, _field} -> :ok
      {:error, error} -> throw({__MODULE__, field, error})
    end
  end

  # Only inside `AfterCommit.deferring/1`: `BustFormCache` goes through
  # `AfterCommit.run/1`, so silencing Ash's nested-hook warning is sound.
  defp with_after_commit_context(opts),
    do:
      Keyword.update(opts, :context, AfterCommit.context(), &Map.merge(&1, AfterCommit.context()))
end
