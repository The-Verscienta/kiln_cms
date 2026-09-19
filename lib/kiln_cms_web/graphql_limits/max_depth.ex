defmodule KilnCMSWeb.GraphqlLimits.MaxDepth do
  @moduledoc """
  Refuses an operation whose fields nest deeper than `:max_depth`. See
  `KilnCMSWeb.GraphqlLimits` for why the complexity cap alone is not enough.

  Depth counts fields only. An inline fragment or a fragment spread adds no
  level, so moving a selection into a fragment does not make it shallower. The
  depth of each named fragment is computed once and reused wherever it is spread.
  A document that spreads one fragment many times is therefore checked in time
  linear in its size, not its expanded size.

  A fragment cycle is reported by `Absinthe.Phase.Document.Validation.NoFragmentCycles`,
  which ends the pipeline before this phase runs. The walk still ends on one:
  a fragment spread inside itself counts as depth 0, so the phase is safe on any
  blueprint.
  """
  use Absinthe.Phase

  alias Absinthe.Blueprint
  alias Absinthe.Blueprint.Document.{Field, Fragment}

  @impl Absinthe.Phase
  def run(%Blueprint{} = blueprint, opts) do
    max_depth = Keyword.fetch!(opts, :max_depth)
    fragments = Map.new(blueprint.fragments, &{&1.name, &1})

    {operations, _memo} =
      Enum.map_reduce(blueprint.operations, %{}, fn operation, memo ->
        {depth, memo} = selections_depth(operation.selections, fragments, memo)
        {check(operation, depth, max_depth), memo}
      end)

    {:ok, %{blueprint | operations: operations}}
  end

  defp check(operation, depth, max_depth) when depth <= max_depth, do: operation

  defp check(operation, depth, max_depth) do
    operation
    |> flag_invalid(:too_deep)
    |> put_error(%Absinthe.Phase.Error{
      phase: __MODULE__,
      message:
        "Operation is too deep: fields nest #{depth} levels and the maximum is #{max_depth}",
      locations: [operation.source_location]
    })
  end

  defp selections_depth(selections, fragments, memo) do
    Enum.reduce(selections, {0, memo}, fn selection, {deepest, memo} ->
      {depth, memo} = selection_depth(selection, fragments, memo)
      {max(deepest, depth), memo}
    end)
  end

  defp selection_depth(%Field{selections: selections}, fragments, memo) do
    {depth, memo} = selections_depth(selections, fragments, memo)
    {depth + 1, memo}
  end

  defp selection_depth(%Fragment.Inline{selections: selections}, fragments, memo) do
    selections_depth(selections, fragments, memo)
  end

  defp selection_depth(%Fragment.Spread{name: name}, fragments, memo) do
    case {memo, fragments} do
      {%{^name => depth}, _fragments} ->
        {depth, memo}

      {_memo, %{^name => fragment}} ->
        # Recorded as 0 while its own selections are walked, so a spread of it
        # from inside itself (a cycle) ends the walk.
        {depth, memo} = selections_depth(fragment.selections, fragments, Map.put(memo, name, 0))
        {depth, Map.put(memo, name, depth)}

      # An unknown fragment — `KnownFragmentNames` reports it.
      _unknown ->
        {0, memo}
    end
  end

  defp selection_depth(_other, _fragments, memo), do: {0, memo}
end
