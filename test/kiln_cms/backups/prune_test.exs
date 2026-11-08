defmodule KilnCMS.Backups.PruneTest do
  @moduledoc """
  Retention treats the files of one stamp as ONE set (#2218): the dump, the
  media parts (or the legacy single archive) and the checksum sidecars, aged by
  the newest member and deleted together.
  """
  # `async: false`: points `:kiln_cms, KilnCMS.Backups` at a temp directory
  # (`Application.put_env` is VM-global).
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Recorder, Worker}

  @moduletag :capture_log

  @old_stamp "20200101-000000"
  @day 24 * 3600

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_prune_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))
    File.mkdir_p!(Path.join([dir, ".work", @old_stamp]))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])

    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(original, dir: dir, keep_days: 14)
    )

    on_exit(fn ->
      File.chmod(Path.join(dir, "media"), 0o700)
      File.rm_rf!(dir)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
    end)

    %{dir: dir}
  end

  # A file `days` days old under `sub`.
  defp put(dir, sub, name, days) do
    path = Path.join([dir, sub, name])
    File.write!(path, "x")
    File.touch!(path, System.os_time(:second) - days * @day)
    path
  end

  defp media_set(dir, stamp, ages) do
    for {age, i} <- Enum.with_index(ages, 1),
        do: put(dir, "media", Artifact.part_name(stamp, i), age)
  end

  defp left(dir) do
    for sub <- ["db", "media"], name <- File.ls!(Path.join(dir, sub)), do: "#{sub}/#{name}"
  end

  test "one very old member does not take a set with a fresh newest member", %{dir: dir} do
    # part01 is a year old, part02 was written a minute ago.
    media_set(dir, @old_stamp, [365, 0])
    put(dir, "media", Artifact.sidecar_name(:media, @old_stamp), 365)

    assert Worker.prune(dir) == []

    assert Enum.sort(left(dir)) ==
             Enum.sort([
               "media/kiln-media-#{@old_stamp}.part01.tar.gz",
               "media/kiln-media-#{@old_stamp}.part02.tar.gz",
               "media/kiln-media-#{@old_stamp}.sha256"
             ])
  end

  test "a set whose newest member is old goes whole, sidecars included", %{dir: dir} do
    media_set(dir, @old_stamp, [400, 380, 365])
    put(dir, "media", Artifact.sidecar_name(:media, @old_stamp), 365)
    put(dir, "db", "kiln-db-#{@old_stamp}.dump", 365)
    put(dir, "db", Artifact.sidecar_name(:db, @old_stamp), 365)

    deleted = Worker.prune(dir)

    assert left(dir) == []

    assert Enum.sort(deleted) ==
             Enum.sort([
               "kiln-media-#{@old_stamp}.part01.tar.gz",
               "kiln-media-#{@old_stamp}.part02.tar.gz",
               "kiln-media-#{@old_stamp}.part03.tar.gz",
               "kiln-media-#{@old_stamp}.sha256",
               "kiln-db-#{@old_stamp}.dump",
               "kiln-db-#{@old_stamp}.sha256"
             ])
  end

  test "a fresh dump keeps the old media parts of the same stamp (and vice versa)", %{dir: dir} do
    media_set(dir, @old_stamp, [365, 365])
    put(dir, "db", "kiln-db-#{@old_stamp}.dump", 0)

    assert Worker.prune(dir) == []
    assert length(left(dir)) == 3
  end

  test "a fresh sidecar keeps an old set: the newest member decides", %{dir: dir} do
    media_set(dir, @old_stamp, [365, 365])
    put(dir, "media", Artifact.sidecar_name(:media, @old_stamp), 1)

    assert Worker.prune(dir) == []
    assert length(left(dir)) == 3
  end

  test "orphan parts of a failed run and a gap set age out together", %{dir: dir} do
    # parts 1 and 3 only (part02 never landed), all old
    put(dir, "media", Artifact.part_name(@old_stamp, 1), 300)
    put(dir, "media", Artifact.part_name(@old_stamp, 3), 300)
    # a lone orphan part of another stamp
    put(dir, "media", Artifact.part_name("20200202-000000", 1), 300)

    assert length(Worker.prune(dir)) == 3
    assert left(dir) == []
  end

  test "a legacy single archive and its db of an old stamp are pruned; a young stamp stays",
       %{dir: dir} do
    put(dir, "media", "kiln-media-#{@old_stamp}.tar.gz", 100)
    put(dir, "db", "kiln-db-#{@old_stamp}.dump", 100)
    put(dir, "media", "kiln-media-20990101-000000.tar.gz", 1)

    assert length(Worker.prune(dir)) == 2
    assert left(dir) == ["media/kiln-media-20990101-000000.tar.gz"]
  end

  test "the (keep_days + 1) day boundary matches the shell", %{dir: dir} do
    media_set(dir, "20200101-000000", [14])
    media_set(dir, "20200202-000000", [16])

    assert ["kiln-media-20200202-000000.part01.tar.gz"] = Worker.prune(dir)
  end

  test ".partial files and the .work directory are never touched", %{dir: dir} do
    partial = put(dir, "media", "kiln-media-#{@old_stamp}.part01.tar.gz.partial", 365)
    put(dir, "db", "kiln-db-#{@old_stamp}.sha256.partial", 365)
    list = Path.join([dir, ".work", @old_stamp, "part01.list"])
    File.write!(list, "x")
    File.touch!(list, System.os_time(:second) - 365 * @day)

    assert Worker.prune(dir) == []
    assert File.exists?(partial)
    assert File.exists?(list)
    assert length(left(dir)) == 2
  end

  test "a stray kiln-* file that is no set member ages alone", %{dir: dir} do
    put(dir, "media", "kiln-media-notes.txt", 400)
    put(dir, "media", "kiln-media-other.txt", 0)

    assert ["kiln-media-notes.txt"] = Worker.prune(dir)
  end

  test "a removal that fails stops that set instead of skipping past it", %{dir: dir} do
    media_set(dir, @old_stamp, [365, 365])
    File.chmod!(Path.join(dir, "media"), 0o500)

    if File.touch(Path.join([dir, "media", "probe"])) == {:error, :eacces} do
      assert Worker.prune(dir) == []
      File.chmod!(Path.join(dir, "media"), 0o700)
      assert length(left(dir)) == 2
    else
      File.chmod!(Path.join(dir, "media"), 0o700)
    end
  end

  describe "the run history" do
    defp run_with(artifacts, stamp \\ @old_stamp) do
      run =
        Backups.start_run!(
          %{stamp: stamp, trigger: "manual", started_at: ~U[2020-01-01 00:00:00Z]},
          actor: Backups.system()
        )

      Backups.finish_run!(run, %{artifacts: artifacts}, actor: Backups.system())
    end

    defp stored(stamp \\ @old_stamp),
      do: Backups.get_run_by_stamp!(stamp, actor: Backups.system())

    test "marks the whole part set and each part pruned; the sidecar name is ignored" do
      names = Artifact.set_names(@old_stamp, 2)

      parts =
        for name <- names, do: %{"name" => name, "bytes" => 1, "sha256" => nil}

      run_with([
        %{
          kind: :media,
          name: "kiln-media-#{@old_stamp}",
          bytes: 2,
          parts: parts,
          destinations: %{
            "local" => %{"status" => "ok"},
            "rclone:r2" => %{"status" => "ok"}
          }
        }
      ])

      Recorder.mark_pruned(names ++ [Artifact.sidecar_name(:media, @old_stamp)])

      assert [artifact] = stored().artifacts

      assert %{"local" => %{"status" => "pruned"}, "rclone:r2" => %{"status" => "ok"}} =
               artifact.destinations

      assert Enum.all?(artifact.parts, &(&1["destinations"]["local"]["status"] == "pruned"))
    end

    test "a set pruned only in part marks those parts, not the artifact" do
      [one, two] = Artifact.set_names(@old_stamp, 2)

      run_with([
        %{
          kind: :media,
          name: "kiln-media-#{@old_stamp}",
          bytes: 2,
          parts: [%{"name" => one, "bytes" => 1}, %{"name" => two, "bytes" => 1}],
          destinations: %{"local" => %{"status" => "ok"}}
        }
      ])

      Recorder.mark_pruned([one])

      assert [artifact] = stored().artifacts
      assert artifact.destinations["local"]["status"] == "ok"
      assert [%{"destinations" => %{"local" => %{"status" => "pruned"}}}, second] = artifact.parts
      refute Map.has_key?(second, "destinations")
    end

    test "end to end: Worker.prune + mark_pruned on a legacy single file", %{dir: dir} do
      put(dir, "media", "kiln-media-#{@old_stamp}.tar.gz", 365)

      {:ok, attrs} =
        Artifact.from_manifest(%{kind: "media", path: "media/kiln-media-#{@old_stamp}.tar.gz"})

      run_with([attrs])
      dir |> Worker.prune() |> Recorder.mark_pruned()

      assert [%{destinations: %{"local" => %{"status" => "pruned"}}}] = stored().artifacts
    end
  end
end
