defmodule Kiln.Block.MigrationChain do
  @moduledoc """
  Compile-time check that a block's `migrate` steps form one contiguous chain
  from version 1 up to its declared `version` (#1642).

  `KilnCMS.Blocks.Upcaster` follows the chain from a stored block's `_version`
  to the head version, one step at a time. A stored version the chain cannot
  carry to head — a missing step, a step that runs backwards, one that
  overshoots the declared version — is **refused** at runtime: the block is
  left exactly as stored, `_version` included. This verifier reports the same
  problem when the block module compiles, so it reaches you before any data
  does.

  It is a **warning**, not an error, for the 0.x series: a block module that
  compiled before 0.12 must keep compiling. It becomes a compile error in
  Kiln 2.0. Under `mix compile --warnings-as-errors` it already fails the
  build — which is the point: a gap means stored blocks at that version never
  reach the shape the renderer expects.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl Spark.Dsl.Verifier
  def verify(dsl_state) do
    case Verifier.get_entities(dsl_state, [:kiln_block]) do
      [%Kiln.Block.Definition{} = definition] ->
        module = Verifier.get_persisted(dsl_state, :module)

        case problems(definition.version || 1, definition.migrations) do
          [] -> :ok
          found -> {:warn, Enum.map(found, &warning(&1, module, definition))}
        end

      # None or several `block`s: `Kiln.Block.Transformer` already refused it.
      _other ->
        :ok
    end
  end

  @doc """
  What is wrong with a declared migration chain, as sentences; `[]` when the
  steps carry every version from 1 to `version`.

      iex> Kiln.Block.MigrationChain.problems(3, [%{from: 1, to: 2}, %{from: 2, to: 3}])
      []

      iex> Kiln.Block.MigrationChain.problems(3, [%{from: 1, to: 2}])
      ["no `migrate` step leaves version 2, so stored v1–v2 blocks cannot reach version 3"]
  """
  @spec problems(pos_integer(), [%{from: pos_integer(), to: pos_integer()}]) :: [String.t()]
  def problems(version, migrations) do
    shape_problems(version, migrations) ++
      duplicate_problems(migrations) ++ gap_problems(version, migrations)
  end

  defp shape_problems(version, migrations) do
    Enum.flat_map(migrations, fn
      %{from: from, to: to} when to <= from ->
        ["`migrate from: #{from}, to: #{to}` does not move forward"]

      %{from: from, to: to} when to > version ->
        ["`migrate from: #{from}, to: #{to}` goes past the block's declared version #{version}"]

      _step ->
        []
    end)
  end

  defp duplicate_problems(migrations) do
    migrations
    |> Enum.frequencies_by(& &1.from)
    |> Enum.filter(fn {_from, count} -> count > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {from, count} ->
      "#{count} `migrate` steps start at version #{from}; only the last one declared runs"
    end)
  end

  # Walk from version 1 the way the upcaster does. The first version with no
  # usable step onward is the gap; every stored version from 1 up to it is
  # refused at runtime.
  defp gap_problems(version, migrations) do
    steps = Map.new(migrations, &{&1.from, &1})

    case walk(1, version, steps) do
      :ok ->
        []

      {:gap, at} ->
        [
          "no `migrate` step leaves version #{at}, so stored #{span(at)} blocks " <>
            "cannot reach version #{version}"
        ]
    end
  end

  defp span(1), do: "v1"
  defp span(at), do: "v1–v#{at}"

  defp walk(version, version, _steps), do: :ok

  defp walk(at, version, steps) do
    case Map.get(steps, at) do
      %{to: next} when next > at and next <= version -> walk(next, version, steps)
      _missing_or_unusable -> {:gap, at}
    end
  end

  defp warning(problem, module, definition) do
    message =
      "Kiln.Block #{inspect(module)} (:#{definition.name}, version #{definition.version}): " <>
        problem <>
        ". KilnCMS.Blocks.Upcaster refuses to upcast a stored block it cannot carry to the " <>
        "declared version and leaves it as stored. Declare the missing `migrate` step. " <>
        "This warning becomes a compile error in Kiln 2.0."

    case Spark.Dsl.Entity.anno(definition) do
      nil -> message
      anno -> {message, anno}
    end
  end
end
