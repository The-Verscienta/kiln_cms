defmodule KilnCMS.Backups.ManifestTest do
  # Pure file I/O in a private tmp dir.
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.Manifest

  @hex String.duplicate("cd", 32)

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_manifest_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # A manifest exactly as the writer produced it before #2218: four keys per
  # artifact. A reader change must keep reading this identically.
  @pre_change """
  {
    "version": 1,
    "started_at": "2026-08-05T03:17:00Z",
    "finished_at": "2026-08-05T03:18:42Z",
    "trigger": "cron",
    "ok": true,
    "artifacts": [
      {"kind": "db", "path": "db/kiln-db-20260805-031700.dump", "bytes": 48317216, "verified": true},
      {"kind": "media", "path": "media/kiln-media-20260805-031700.tar.gz", "bytes": 1000, "verified": false}
    ],
    "offsite": "r2:kiln-backups",
    "keep_days": 14,
    "error": null
  }
  """

  test "a pre-#2218 manifest reads identically: no new keys appear", %{dir: dir} do
    File.write!(Manifest.path(dir), @pre_change)
    manifest = Manifest.read(dir)

    assert manifest.version == 1

    assert manifest.artifacts == [
             %{
               kind: "db",
               path: "db/kiln-db-20260805-031700.dump",
               bytes: 48_317_216,
               verified: true
             },
             %{
               kind: "media",
               path: "media/kiln-media-20260805-031700.tar.gz",
               bytes: 1000,
               verified: false
             }
           ]

    assert Manifest.total_bytes(manifest) == 48_318_216
    refute Manifest.verified?(manifest)
  end

  test "writing entries without the new keys emits the old four-key shape", %{dir: dir} do
    entry = %{kind: "db", path: "db/a.dump", bytes: 1, verified: true}
    :ok = Manifest.write(dir, %Manifest{artifacts: [entry]})

    assert [written] =
             dir |> Manifest.path() |> File.read!() |> Jason.decode!() |> Map.fetch!("artifacts")

    assert Map.keys(written) |> Enum.sort() == ["bytes", "kind", "path", "verified"]
  end

  test "sha256, part and parts_total round-trip on flat entries in part order", %{dir: dir} do
    artifacts =
      for n <- 1..3 do
        %{
          kind: "media",
          path: "media/kiln-media-20260805-031700.part0#{n}.tar.gz",
          bytes: 100 * n,
          verified: true,
          sha256: @hex,
          part: n,
          parts_total: 3
        }
      end

    :ok = Manifest.write(dir, %Manifest{ok: true, version: 1, artifacts: artifacts})

    json = dir |> Manifest.path() |> File.read!() |> Jason.decode!()
    assert json["version"] == 1
    assert [%{"sha256" => @hex, "part" => 1, "parts_total" => 3} | _] = json["artifacts"]

    read = Manifest.read(dir)
    assert read.artifacts == artifacts
    assert Manifest.total_bytes(read) == 600
    assert Manifest.verified?(read)
  end

  test "one unverified part makes the manifest unverified", %{dir: dir} do
    artifacts = [
      %{kind: "media", path: "media/a.part01.tar.gz", bytes: 1, verified: true, part: 1},
      %{kind: "media", path: "media/a.part02.tar.gz", bytes: 1, verified: false, part: 2}
    ]

    :ok = Manifest.write(dir, %Manifest{artifacts: artifacts})
    refute dir |> Manifest.read() |> Manifest.verified?()
  end

  test "malformed new keys are dropped, not trusted", %{dir: dir} do
    File.write!(Manifest.path(dir), ~s({"artifacts": [
      {"kind": "db", "path": "db/a.dump", "bytes": 1, "verified": true,
       "sha256": "short", "part": 0, "parts_total": "x"}]}))

    assert [entry] = Manifest.read(dir).artifacts
    assert Map.keys(entry) |> Enum.sort() == [:bytes, :kind, :path, :verified]
  end

  test "keep_days is a whole number of days, 1 or more, or absent (#2727)", %{dir: dir} do
    # The type says `pos_integer | nil`; a hand-edited or pre-#2727 cron
    # manifest could say 0 or -1, which no retention ever meant.
    for {raw, expected} <- [{14, 14}, {1, 1}, {0, nil}, {-1, nil}, {"14", nil}, {1.5, nil}] do
      File.write!(Manifest.path(dir), Jason.encode!(%{"ok" => true, "keep_days" => raw}))
      assert Manifest.read(dir).keep_days == expected, inspect(raw)
    end
  end

  describe "stamp" do
    test "round-trips, and a manifest without it reads nil and writes no key", %{dir: dir} do
      :ok = Manifest.write(dir, %Manifest{stamp: "20261111-145226"})
      assert Manifest.read(dir).stamp == "20261111-145226"

      :ok = Manifest.write(dir, %Manifest{})
      refute dir |> Manifest.path() |> File.read!() |> Jason.decode!() |> Map.has_key?("stamp")

      File.write!(Manifest.path(dir), @pre_change)
      assert Manifest.read(dir).stamp == nil
    end

    test "one that is not a real instant reads as absent", %{dir: dir} do
      for bad <- ["20261340-996199", "../../etc", 20_261_111, ""] do
        File.write!(Manifest.path(dir), Jason.encode!(%{"stamp" => bad}))
        assert Manifest.read(dir).stamp == nil
      end
    end
  end
end
