defmodule Kiln.Block.MigrationChainTest do
  @moduledoc "The compile-time contiguity check on a block's `migrate` steps (#1642)."
  use ExUnit.Case, async: true

  alias Kiln.Block.MigrationChain

  doctest MigrationChain

  defp step(from, to), do: %{from: from, to: to}

  test "version 1 with no steps, and a full chain, are clean" do
    assert MigrationChain.problems(1, []) == []
    assert MigrationChain.problems(4, [step(1, 2), step(2, 3), step(3, 4)]) == []
  end

  test "a step that jumps versions still chains" do
    assert MigrationChain.problems(3, [step(1, 3)]) == []
  end

  test "a version above 1 with no steps is a gap at 1" do
    assert [problem] = MigrationChain.problems(2, [])
    assert problem =~ "no `migrate` step leaves version 1"
  end

  test "a missing middle step is a gap at that version" do
    assert [problem] = MigrationChain.problems(4, [step(1, 2), step(3, 4)])
    assert problem =~ "leaves version 2"
  end

  test "backwards, overshooting and duplicate steps are each named" do
    problems = MigrationChain.problems(3, [step(1, 2), step(2, 1), step(2, 5), step(1, 2)])

    assert Enum.any?(problems, &(&1 =~ "from: 2, to: 1` does not move forward"))

    assert Enum.any?(
             problems,
             &(&1 =~ "from: 2, to: 5` goes past the block's declared version 3")
           )

    assert Enum.any?(problems, &(&1 =~ "2 `migrate` steps start at version 1"))
    assert Enum.any?(problems, &(&1 =~ "leaves version 2"))
  end

  test "every block the core ships has a clean chain" do
    for module <- KilnCMS.Blocks.modules() do
      assert MigrationChain.problems(
               Kiln.Block.Info.version(module) || 1,
               Kiln.Block.Info.migrations(module)
             ) == [],
             inspect(module)
    end
  end
end
