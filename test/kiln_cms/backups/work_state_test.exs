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

  describe "tagged writes (#2818)" do
    setup %{tmp_dir: dir} do
      work = WorkState.path(dir, @stamp)
      File.mkdir_p!(work)
      :ok = WorkState.write(work, WorkState.new(@stamp, %{"chain" => "theirs"}))
      %{work: work}
    end

    test "a tag writes its own temporary file, and the rename function puts it in place",
         %{work: work} do
      parent = self()

      rename = fn from, to ->
        send(parent, {:rename, from, to, File.read!(from)})
        File.rename(from, to)
      end

      staged = fn tmp ->
        send(parent, {:staged, tmp, File.stat!(tmp).mode})
        :ok
      end

      state = WorkState.new(@stamp, %{"chain" => "ours"})
      assert :ok = WorkState.write(work, state, tag: "48211-2", rename: rename, staged: staged)

      tmp = WorkState.file(work) <> ".48211-2.partial"
      assert_received {:staged, ^tmp, mode}
      assert Bitwise.band(mode, 0o777) == 0o600
      assert_received {:rename, ^tmp, to, json}
      assert to == WorkState.file(work)
      assert Jason.decode!(json)["chain"] == "ours"

      assert {:ok, %{"chain" => "ours"}} = WorkState.read(work)
      assert File.ls!(work) == ["state.json"]
    end

    test "a refused rename leaves the state as it was and no temporary file", %{work: work} do
      refuse = fn _from, _to -> {:error, :superseded} end
      state = WorkState.new(@stamp, %{"chain" => "ours"})

      assert {:error, :superseded} = WorkState.write(work, state, tag: "7-1", rename: refuse)
      assert {:ok, %{"chain" => "theirs"}} = WorkState.read(work)
      assert File.ls!(work) == ["state.json"]

      assert {:error, :superseded} =
               WorkState.update(work, @stamp, &Map.put(&1, "x", 1), tag: "7-1", rename: refuse)

      assert File.ls!(work) == ["state.json"]
    end

    test "without options it writes state.json.partial and renames it, as before",
         %{work: work} do
      # The untagged temporary name is taken: the write fails, nothing lands.
      File.mkdir!(WorkState.file(work) <> ".partial")
      assert {:error, _} = WorkState.write(work, WorkState.new(@stamp, %{"chain" => "ours"}))
      assert {:ok, %{"chain" => "theirs"}} = WorkState.read(work)

      # A tagged write doesn't touch that name.
      assert :ok = WorkState.write(work, WorkState.new(@stamp, %{"chain" => "ours"}), tag: 9)
      assert {:ok, %{"chain" => "ours"}} = WorkState.read(work)
    end
  end
end
