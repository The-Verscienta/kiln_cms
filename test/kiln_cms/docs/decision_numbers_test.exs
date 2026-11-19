defmodule KilnCMS.Docs.DecisionNumbersTest do
  @moduledoc """
  Every record in `docs/decisions/` has a number of its own, and the file's
  `# NNNN.` heading carries the same number as its file name.

  Two records were merged as 0066 in parallel pull requests (#3015). ADRs are
  never revised, but a number collision is a filing error: this test fails the
  second one to land, so the later PR renumbers before it merges.
  """
  use ExUnit.Case, async: true

  @dir Path.expand("../../../docs/decisions", __DIR__)

  defp records do
    @dir
    |> File.ls!()
    |> Enum.filter(&Regex.match?(~r/^\d{4}-.*\.md$/, &1))
    |> Enum.sort()
  end

  test "no two records share a number" do
    dupes =
      records()
      |> Enum.group_by(&String.slice(&1, 0, 4))
      |> Enum.filter(fn {_n, files} -> length(files) > 1 end)

    assert dupes == [],
           "ADR numbers must be unique; renumber the later-merged record and its links: " <>
             inspect(dupes)
  end

  test "each record's heading carries its file's number" do
    for file <- records() do
      number = String.slice(file, 0, 4)
      [first | _] = @dir |> Path.join(file) |> File.read!() |> String.split("\n", parts: 2)

      assert String.starts_with?(first, "# #{number}. "),
             "#{file} opens with #{inspect(first)}, expected a heading numbered #{number}"
    end
  end
end
