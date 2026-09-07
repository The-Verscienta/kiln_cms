defmodule Mix.Tasks.Kiln.Coverage.MergeTest do
  @moduledoc """
  The completeness guard of `mix kiln.coverage.merge` — the one reason the
  task exists instead of `mix coveralls.multiple --import-cover`. The import
  and reporting behind it are excoveralls' own and are exercised by every CI
  run; what has to be pinned here is that a missing shard is an ERROR, not a
  smaller number.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Kiln.Coverage.Merge

  @moduletag :tmp_dir

  test "returns the shard files, sorted, when the count matches", %{tmp_dir: dir} do
    for n <- [3, 1, 2], do: File.write!(Path.join(dir, "shard-#{n}.coverdata"), "")
    File.write!(Path.join(dir, "notes.txt"), "ignored")

    assert Merge.shard_files!(dir, 3) ==
             Enum.map(1..3, &Path.join(dir, "shard-#{&1}.coverdata"))
  end

  test "without --shards any non-empty set is accepted", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "shard-1.coverdata"), "")

    assert Merge.shard_files!(dir, nil) == [Path.join(dir, "shard-1.coverdata")]
  end

  test "a subset of the shards is an error that names the files found", %{tmp_dir: dir} do
    for n <- [1, 4], do: File.write!(Path.join(dir, "shard-#{n}.coverdata"), "")

    assert_raise Mix.Error,
                 ~r/Expected 6 shard coverdata files .* found 2: shard-1\.coverdata, shard-4\.coverdata/s,
                 fn ->
                   Merge.shard_files!(dir, 6)
                 end
  end

  test "an empty directory is an error, with or without --shards", %{tmp_dir: dir} do
    assert_raise Mix.Error, ~r/No \*\.coverdata files/, fn -> Merge.shard_files!(dir, 6) end
    assert_raise Mix.Error, ~r/No \*\.coverdata files/, fn -> Merge.shard_files!(dir, nil) end
  end
end
