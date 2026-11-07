defmodule KilnCMS.Backups.WorkStateTest do
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.WorkState

  @moduletag :tmp_dir

  @stamp "20260805-031700"
  @hex String.duplicate("ab", 32)

  test "valid_stamp?/1 accepts only a real YYYYMMDD-HHMMSS instant" do
    assert WorkState.valid_stamp?(@stamp)

    for bad <- ["../../x", "20260805-03170", "20260805-0317000", "20261340-996199", "", nil, 1] do
      refute WorkState.valid_stamp?(bad), inspect(bad)
    end
  end

  test "path/2 stays under .work", %{tmp_dir: dir} do
    assert WorkState.path(dir, @stamp) == Path.join([dir, ".work", @stamp])
    assert_raise ArgumentError, fn -> WorkState.path(dir, "..") end
  end

  test "state round-trips atomically at mode 0600", %{tmp_dir: dir} do
    work = WorkState.path(dir, @stamp)
    File.mkdir_p!(work)
    refute WorkState.exists?(work)
    assert {:error, :no_state} = WorkState.read(work)

    state =
      @stamp
      |> WorkState.new()
      |> WorkState.put_dump(%{name: "kiln-db-#{@stamp}.dump", bytes: 10, sha256: @hex})
      |> WorkState.put_part(%{index: 2, name: "p2", bytes: 5, sha256: @hex, files: 3})
      |> WorkState.complete("dump")

    assert :ok = WorkState.write(work, state)
    assert WorkState.exists?(work)
    assert {:ok, read} = WorkState.read(work)
    assert %{"bytes" => 10, "sha256" => @hex} = WorkState.dump(read)
    assert %{"name" => "p2", "files" => 3} = WorkState.part(read, 2)
    assert WorkState.part(read, 1) == nil
    assert WorkState.completed?(read, "dump")
    refute WorkState.completed?(read, "archive")

    assert File.stat!(WorkState.file(work)).mode |> Bitwise.band(0o777) == 0o600
    refute File.exists?(WorkState.file(work) <> ".partial")
  end

  test "an entry without a digest cannot license a reuse", %{tmp_dir: dir} do
    work = WorkState.path(dir, @stamp)
    File.mkdir_p!(work)

    state = %{
      WorkState.new(@stamp)
      | "dump" => %{"name" => "x", "bytes" => 1},
        "parts" => %{"1" => %{"name" => "p", "bytes" => 1, "sha256" => nil}}
    }

    :ok = WorkState.write(work, state)
    {:ok, read} = WorkState.read(work)
    assert WorkState.dump(read) == nil
    assert WorkState.part(read, 1) == nil
  end

  test "a garbled state file reads as no state", %{tmp_dir: dir} do
    work = WorkState.path(dir, @stamp)
    File.mkdir_p!(work)

    for junk <- ["", "not json", "[]", ~s|{"stamp": 3}|] do
      File.write!(WorkState.file(work), junk)
      assert {:error, :no_state} = WorkState.read(work)
    end
  end
end
