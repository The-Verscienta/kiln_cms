defmodule KilnCMS.Backups.MarkersTest do
  @moduledoc "The `.keep` and `.good` markers as the Backups page reads them (#2542)."
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.Markers

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_mrk_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "db"))
    File.mkdir_p!(Path.join(dir, "media"))

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  defp touch(dir, sub, name), do: File.write!(Path.join([dir, sub, name]), "")

  test "reads recovery points and last-good markers per directory", %{dir: dir} do
    touch(dir, "db", "kiln-20260801-031700.keep")
    touch(dir, "media", "kiln-20260802-031700.keep")
    touch(dir, "db", "kiln-20260803-031700.good")
    touch(dir, "media", "kiln-20260804-031700.good")
    touch(dir, "db", "kiln-db-20260803-031700.dump")

    markers = Markers.read(dir)

    assert Markers.recovery_point?(markers, "20260801-031700")
    assert Markers.recovery_point?(markers, "20260802-031700")
    refute Markers.recovery_point?(markers, "20260803-031700")

    assert Markers.last_good_components(markers, "20260803-031700") == [:db]
    assert Markers.last_good_components(markers, "20260804-031700") == [:media]
    assert Markers.last_good_components(markers, "20260801-031700") == []

    assert Markers.last_good(markers, :db) == "20260803-031700"
    assert Markers.last_good(markers, :media) == "20260804-031700"
  end

  test "a stamp marked last good in both directories names both components", %{dir: dir} do
    touch(dir, "db", "kiln-20260803-031700.good")
    touch(dir, "media", "kiln-20260803-031700.good")

    assert Markers.last_good_components(Markers.read(dir), "20260803-031700") == [:db, :media]
  end

  test "of two last-good markers in one directory, the newest answers", %{dir: dir} do
    touch(dir, "db", "kiln-20260803-031700.good")
    touch(dir, "db", "kiln-20260901-031700.good")

    assert Markers.last_good(Markers.read(dir), :db) == "20260901-031700"
  end

  test "marker-shaped names with a bad stamp are ignored", %{dir: dir} do
    touch(dir, "db", "kiln-2026-08-01.keep")
    touch(dir, "db", "kiln-latest.good")
    touch(dir, "db", "other-20260801-031700.good")

    assert Markers.read(dir) == Markers.empty()
  end

  test "a missing directory has no markers, and a nil stamp is never marked", %{dir: dir} do
    File.rm_rf!(Path.join(dir, "media"))
    touch(dir, "db", "kiln-20260801-031700.keep")

    markers = Markers.read(dir)
    assert Markers.last_good(markers, :media) == nil
    refute Markers.recovery_point?(markers, nil)
    assert Markers.last_good_components(markers, nil) == []

    assert Markers.read(Path.join(dir, "nowhere")) == Markers.empty()
    assert Markers.read(nil) == Markers.empty()
  end

  test "a db/ that can't be listed contributes nothing and doesn't raise", %{dir: dir} do
    touch(dir, "media", "kiln-20260802-031700.good")
    # A file where the directory should be: `File.ls/1` fails with `:enotdir`
    # for every user, root included (a 0o000 mode would not stop root).
    File.rm_rf!(Path.join(dir, "db"))
    File.write!(Path.join(dir, "db"), "")
    assert {:error, :enotdir} = File.ls(Path.join(dir, "db"))

    markers = Markers.read(dir)
    assert Markers.last_good(markers, :db) == nil
    assert Markers.last_good(markers, :media) == "20260802-031700"
  end
end
