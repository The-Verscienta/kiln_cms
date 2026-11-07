defmodule KilnCMS.Backups.ArtifactTest do
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.Artifact

  describe "from_manifest/2" do
    test "maps a manifest artifact to attributes, keeping the filename only" do
      assert {:ok, attrs} =
               Artifact.from_manifest(%{
                 kind: "db",
                 path: "db/kiln-db-20260805-031700.dump",
                 bytes: 48_317_216,
                 verified: true
               })

      assert attrs == %{
               kind: :db,
               name: "kiln-db-20260805-031700.dump",
               bytes: 48_317_216,
               verified: true,
               destinations: %{"local" => %{"status" => "ok"}}
             }
    end

    test "an off-site remote becomes a redacted rclone destination" do
      {:ok, attrs} =
        Artifact.from_manifest(
          %{kind: "media", path: "media/kiln-media-20260805-031700.tar.gz", bytes: 1},
          ":s3,access_key_id=AKIAEXAMPLE1234,secret_access_key=wJalrXUtnFEMIk7MDENG:bucket"
        )

      assert [local, "rclone:" <> rest] = attrs.destinations |> Map.keys() |> Enum.sort()
      assert local == "local"
      refute rest =~ "AKIAEXAMPLE1234"
      refute rest =~ "wJalrXUtnFEMIk7MDENG"
      assert attrs.destinations["rclone:" <> rest] == %{"status" => "ok"}
    end

    test "a path-traversing name is reduced to its basename" do
      assert {:ok, %{name: "evil.dump"}} =
               Artifact.from_manifest(%{kind: "db", path: "../../etc/evil.dump", bytes: 1})
    end

    test "unknown kinds, unusable names and bad shapes are :error" do
      assert :error = Artifact.from_manifest(%{kind: "other", path: "x/y.bin", bytes: 1})
      assert :error = Artifact.from_manifest(%{kind: "db", path: "", bytes: 1})
      assert :error = Artifact.from_manifest(%{kind: "db", path: "..", bytes: 1})
      assert :error = Artifact.from_manifest(%{kind: :db, path: "x"})
      assert :error = Artifact.from_manifest(nil)
    end

    test "untrusted bytes and verified are clamped" do
      assert {:ok, %{bytes: 0, verified: false}} =
               Artifact.from_manifest(%{
                 kind: "db",
                 path: "db/a.dump",
                 bytes: -5,
                 verified: "yes"
               })
    end

    test "the result is accepted by the embedded create action" do
      {:ok, attrs} = Artifact.from_manifest(%{kind: "db", path: "db/a.dump", bytes: 3}, "r2:b")

      assert {:ok, artifact} =
               Artifact |> Ash.Changeset.for_create(:create, attrs) |> Ash.create()

      assert artifact.parts == []
      assert artifact.encrypted? == false
      assert artifact.sha256 == nil
    end
  end

  describe "destinations validation" do
    test "rejects an unknown status or key" do
      for bad <- [%{"local" => %{"status" => "weird"}}, %{"s3" => %{"status" => "ok"}}] do
        assert {:error, _} =
                 Artifact
                 |> Ash.Changeset.for_create(:create, %{
                   kind: :db,
                   name: "a.dump",
                   destinations: bad
                 })
                 |> Ash.create()
      end
    end
  end
end
