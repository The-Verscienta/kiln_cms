defmodule KilnCMS.Backups.DirIdTest do
  @moduledoc """
  The backup-directory id (#2218, #2789): `local/1` creates the directory and
  the id, `ensure_existing/1` only gives a directory that already holds
  backups an id, and either publishes the id whole, so a reader never sees a
  malformed one.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.DirId

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_dirid_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp id_files(dir), do: dir |> File.ls!() |> Enum.filter(&String.starts_with?(&1, ".kiln-dir"))

  test "local/1 creates the directory and an id; later calls read it back", %{dir: dir} do
    assert {:ok, id} = DirId.local(dir)
    assert DirId.local(dir) == {:ok, id}
    assert DirId.current(dir) == {:ok, id}
    assert File.read!(DirId.path(dir)) == id <> "\n"
    assert id_files(dir) == [".kiln-dir-id"]
  end

  test "ensure_existing/1 never creates the directory", %{dir: dir} do
    assert DirId.ensure_existing(dir) == {:error, :enoent}
    refute File.exists?(dir)
  end

  test "ensure_existing/1 leaves an empty directory without an id", %{dir: dir} do
    File.mkdir_p!(dir)
    assert DirId.ensure_existing(dir) == {:error, :enoent}
    assert File.ls!(dir) == []
  end

  test "ensure_existing/1 gives a directory with db/ an id, and keeps it", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "db"))
    assert {:ok, id} = DirId.ensure_existing(dir)
    assert DirId.ensure_existing(dir) == {:ok, id}
    assert DirId.local(dir) == {:ok, id}
    assert id_files(dir) == [".kiln-dir-id"]
  end

  test "ensure_existing/1 leaves a malformed id as it is", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "media"))
    File.write!(DirId.path(dir), "")
    assert DirId.ensure_existing(dir) == {:error, :malformed_dir_id}
    assert File.read!(DirId.path(dir)) == ""
  end

  test "an unwritable directory: the error, and no temporary file", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "db"))
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod(dir, 0o700) end)

    assert DirId.ensure_existing(dir) == {:error, :eacces}
    assert id_files(dir) == []
  end

  # A filesystem without hard links: FAT gives EPERM, a FUSE mount without
  # link support ENOSYS, some CIFS mounts EOPNOTSUPP. The id is still
  # published, by the exclusive create of its name.
  for reason <- [:enosys, :eopnotsupp, :eperm, :enotsup] do
    test "a link that fails with #{reason} still publishes a valid id", %{dir: dir} do
      File.mkdir_p!(dir)
      assert {:ok, id} = DirId.publish(dir, fn _, _ -> {:error, unquote(reason)} end)
      assert DirId.current(dir) == {:ok, id}
      assert File.read!(DirId.path(dir)) == id <> "\n"
      assert id_files(dir) == [".kiln-dir-id"]
    end
  end

  test "with no link support, a second publisher reads the first one's id", %{dir: dir} do
    no_link = fn _, _ -> {:error, :enosys} end
    File.mkdir_p!(dir)
    assert {:ok, id} = DirId.publish(dir, no_link)
    assert DirId.publish(dir, no_link) == {:ok, id}
    assert id_files(dir) == [".kiln-dir-id"]
  end

  test "with no link support, an error the create also hits is returned", %{dir: dir} do
    File.mkdir_p!(dir)
    on_exit(fn -> File.chmod(dir, 0o700) end)

    # The directory turns read-only between the temporary file and the link,
    # so the create of the name fails as the link would have.
    ln = fn _, _ ->
      File.chmod!(dir, 0o500)
      {:error, :enosys}
    end

    assert DirId.publish(dir, ln) == {:error, :eacces}
    refute File.exists?(DirId.path(dir))
  end

  # Reads the id until one is there; any read that is neither "none yet" nor
  # an id is returned.
  defp spin_read(dir) do
    case DirId.current(dir) do
      {:ok, id} -> {:ok, id}
      {:error, :enoent} -> spin_read(dir)
      other -> other
    end
  end

  test "racing creators all settle on one id, and no reader sees a malformed one",
       %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "db"))

    for _round <- 1..500 do
      File.rm(DirId.path(dir))

      # Readers spin from before the first creator starts until an id is
      # there, so one that lands between an exclusive create and its write
      # would see an empty file.
      readers = for _ <- 1..8, do: Task.async(fn -> spin_read(dir) end)

      creators =
        for n <- 1..8 do
          Task.async(fn ->
            receive do
              :go -> :ok
            end

            if rem(n, 2) == 0, do: DirId.local(dir), else: DirId.ensure_existing(dir)
          end)
        end

      Enum.each(creators, &send(&1.pid, :go))
      created = Task.await_many(creators, 5_000)
      read = Task.await_many(readers, 5_000)

      assert {:ok, id} = DirId.current(dir)
      assert Enum.uniq(created) == [{:ok, id}]
      assert Enum.uniq(read) == [{:ok, id}]
      assert id_files(dir) == [".kiln-dir-id"]
    end
  end
end
