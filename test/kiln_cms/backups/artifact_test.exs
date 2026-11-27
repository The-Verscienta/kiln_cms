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

  describe "parse_file/1 and parse_name/1 (#2218)" do
    test "single files" do
      assert {:ok, %{kind: :db, stamp: "20260805-031700", part: nil, partial?: false}} =
               Artifact.parse_file("kiln-db-20260805-031700.dump")

      assert {:ok, %{kind: :media, part: nil, partial?: false}} =
               Artifact.parse_file("kiln-media-20260805-031700.tar.gz")

      assert {:ok, %{kind: :db, partial?: true}} =
               Artifact.parse_file("kiln-db-20260805-031700.dump.partial")
    end

    test "media parts parse to their integer, with and without .partial" do
      assert {:ok, %{kind: :media, stamp: "20260805-031700", part: 1, partial?: false}} =
               Artifact.parse_file("kiln-media-20260805-031700.part01.tar.gz")

      assert {:ok, %{part: 12, partial?: true}} =
               Artifact.parse_file("kiln-media-20260805-031700.part12.tar.gz.partial")

      assert {:ok, %{part: 100}} =
               Artifact.parse_file("kiln-media-20260805-031700.part100.tar.gz")

      assert {:ok, %{part: 1234}} =
               Artifact.parse_file("kiln-media-20260805-031700.part1234.tar.gz")
    end

    test "things that are not artifacts are refused" do
      for name <- [
            "kiln-db-20260805-031700.part01.dump",
            "kiln-db-20260805-031700.tar.gz",
            "kiln-media-20260805-031700.dump",
            "kiln-media-20260805-031700.part1.tar.gz",
            "kiln-media-20260805-031700.part00.tar.gz",
            "kiln-media-20260805-031700.part001.tar.gz",
            "kiln-media-20260805-031700.partab.tar.gz",
            "kiln-media-20260805-031700.sha256",
            "kiln-media-20260805-031700.part01.tar.gz.partial.partial",
            "x/kiln-media-20260805-031700.tar.gz",
            "kiln-media-20260805-031700.tar.gz\n"
          ] do
        assert Artifact.parse_file(name) == :error, name
      end

      assert Artifact.parse_file(nil) == :error
    end

    test "parse_name/1 keeps the pre-#2218 tuple" do
      assert Artifact.parse_name("kiln-db-20260805-031700.dump") ==
               {:ok, :db, "20260805-031700", false}

      assert Artifact.parse_name("kiln-media-20260805-031700.tar.gz.partial") ==
               {:ok, :media, "20260805-031700", true}

      assert Artifact.parse_name("kiln-media-20260805-031700.part02.tar.gz") ==
               {:ok, :media, "20260805-031700", false}

      assert Artifact.parse_name("nope") == :error
    end
  end

  describe "tagged temporary names (#2819)" do
    test "a backup step's tagged partials parse like the untagged ones" do
      assert {:ok, %{kind: :db, stamp: "20260805-031700", part: nil, partial?: true}} =
               Artifact.parse_file("kiln-db-20260805-031700.dump.48211-2.partial")

      assert {:ok, %{kind: :db, partial?: true}} =
               Artifact.parse_file("kiln-db-20260805-031700.dump.48211.partial")

      assert {:ok, %{kind: :media, part: 2, partial?: true}} =
               Artifact.parse_file("kiln-media-20260805-031700.part02.tar.gz.48211-1.partial")

      assert {:ok, %{kind: :media, part: nil, partial?: true}} =
               Artifact.parse_file("kiln-media-20260805-031700.tar.gz.7-3.partial")

      assert {:ok, %{kind: :media, stamp: "20260805-031700", partial?: true}} =
               Artifact.parse_sidecar_name("kiln-media-20260805-031700.sha256.48211-2.partial")

      assert {:ok, %{kind: :db, partial?: true}} =
               Artifact.parse_sidecar_name("kiln-db-20260805-031700.sha256.48211.partial")
    end

    test "anything else around .partial is refused, by both parsers" do
      for name <- [
            # a tag without .partial
            "kiln-db-20260805-031700.dump.48211",
            "kiln-db-20260805-031700.dump.48211-2",
            # not digits
            "kiln-db-20260805-031700.dump.4a1.partial",
            "kiln-db-20260805-031700.dump.-2.partial",
            "kiln-db-20260805-031700.dump.48211-.partial",
            "kiln-db-20260805-031700.dump..partial",
            # two tags, or three numbers
            "kiln-db-20260805-031700.dump.1.2.partial",
            "kiln-db-20260805-031700.dump.1-2-3.partial",
            # the tag after .partial
            "kiln-db-20260805-031700.dump.partial.48211",
            "kiln-media-20260805-031700.part01.tar.gz.partial.48211-2"
          ] do
        assert Artifact.parse_file(name) == :error, name
      end

      for name <- [
            "kiln-db-20260805-031700.sha256.48211",
            "kiln-db-20260805-031700.sha256.x.partial",
            "kiln-db-20260805-031700.sha256.1.2.partial",
            "kiln-db-20260805-031700.sha256.partial.48211"
          ] do
        assert Artifact.parse_sidecar_name(name) == :error, name
      end
    end

    test "name_stamp/1 reads the stamp of any file of either kind, and nothing else (#2477)" do
      for name <- [
            "kiln-db-20260805-031700.dump",
            "kiln-db-20260805-031700.dump.partial",
            "kiln-db-20260805-031700.sha256",
            "kiln-media-20260805-031700.tar.gz",
            "kiln-media-20260805-031700.part03.tar.gz.48211-2.partial",
            "kiln-media-20260805-031700.sha256.partial"
          ] do
        assert Artifact.name_stamp(name) == {:ok, "20260805-031700"}, name
      end

      for name <- [
            "kiln-20260805-031700.keep",
            "kiln-db-20260805-031700",
            "kiln-db-2026080-031700.dump",
            "kiln-files-20260805-031700.dump",
            "manifest.json",
            "x-kiln-db-20260805-031700.dump"
          ] do
        assert Artifact.name_stamp(name) == :error, name
      end
    end

    test "a file kept after a refusal is no artifact or sidecar, and carries its backup's stamp (#2484)" do
      at = ~U[2026-11-18 10:15:00Z]

      for {name, kind} <- [
            {"kiln-db-20260805-031700.dump", :db},
            {"kiln-db-20260805-031700.sha256", :db},
            {"kiln-media-20260805-031700.tar.gz", :media},
            {"kiln-media-20260805-031700.part03.tar.gz", :media},
            {"kiln-media-20260805-031700.sha256", :media}
          ] do
        kept = Artifact.refused_name(name, at)
        assert kept == name <> ".refused-20261118-101500"
        assert Artifact.parse_file(kept) == :error, kept
        assert Artifact.parse_sidecar_name(kept) == :error, kept
        refute KilnCMS.Backups.Destination.backup_file?(kept)
        # The backup's stamp, never the refusal's: the stamp stays in use.
        assert Artifact.name_stamp(kept) == {:ok, "20260805-031700"}

        assert Artifact.parse_refused_name(kept) ==
                 {:ok,
                  %{
                    name: name,
                    kind: kind,
                    stamp: "20260805-031700",
                    refused_at: "20261118-101500"
                  }}
      end

      for name <- [
            "kiln-db-20260805-031700.dump",
            "kiln-db-20260805-031700.dump.partial.refused-20261118-101500",
            "kiln-db-20260805-031700.dump.refused-20261118",
            "kiln-db-20260805-031700.dump.refused-20261118-101500.partial",
            "kiln-notes.txt.refused-20261118-101500",
            "kiln-20260805-031700.keep.refused-20261118-101500"
          ] do
        assert Artifact.parse_refused_name(name) == :error, name
      end
    end

    test "partial_name/2 builds what the parsers read" do
      assert Artifact.partial_name("kiln-db-20260805-031700.dump", nil) ==
               "kiln-db-20260805-031700.dump.partial"

      assert Artifact.partial_name("kiln-db-20260805-031700.dump", 48_211) ==
               "kiln-db-20260805-031700.dump.48211.partial"

      tag = Artifact.tag(48_211, 2)
      assert tag == "48211-2"

      for name <- [
            "kiln-db-20260805-031700.dump",
            "kiln-media-20260805-031700.part03.tar.gz",
            "kiln-media-20260805-031700.tar.gz"
          ] do
        assert {:ok, %{partial?: true}} = Artifact.parse_file(Artifact.partial_name(name, tag))
      end

      assert {:ok, %{partial?: true}} =
               Artifact.parse_sidecar_name(
                 Artifact.partial_name("kiln-media-20260805-031700.sha256", tag)
               )

      assert Artifact.partial_name("/w/state.json", tag) == "/w/state.json.48211-2.partial"
    end

    test "partial_name/2 refuses a tag that isn't one" do
      for tag <- ["4a1", "1.2", "../x", "", "1-2-3", "-2"] do
        assert_raise ArgumentError, fn -> Artifact.partial_name("x", tag) end
        refute Artifact.tag?(tag)
      end

      for tag <- [0, -1] do
        assert_raise FunctionClauseError, fn -> Artifact.partial_name("x", tag) end
      end

      assert Artifact.tag?("1-2")
      assert Artifact.tag?("12")
    end
  end

  describe "naming (#2218)" do
    test "part_name/2 is two digits wide and widens past 99" do
      assert Artifact.part_name("20260805-031700", 1) ==
               "kiln-media-20260805-031700.part01.tar.gz"

      assert Artifact.part_name("20260805-031700", 99) ==
               "kiln-media-20260805-031700.part99.tar.gz"

      assert Artifact.part_name("20260805-031700", 100) ==
               "kiln-media-20260805-031700.part100.tar.gz"
    end

    test "every name part_name/2 builds parses back to its index" do
      for n <- [1, 9, 10, 99, 100, 101, 1000] do
        assert {:ok, %{part: ^n, kind: :media}} =
                 Artifact.parse_file(Artifact.part_name("20260805-031700", n))
      end
    end

    test "a single-part set keeps the legacy name, two or more use .partNN" do
      assert Artifact.set_names("20260805-031700", 1) == ["kiln-media-20260805-031700.tar.gz"]

      assert Artifact.set_names("20260805-031700", 2) == [
               "kiln-media-20260805-031700.part01.tar.gz",
               "kiln-media-20260805-031700.part02.tar.gz"
             ]

      assert length(Artifact.set_names("20260805-031700", 101)) == 101
    end

    test "sidecar_name/2" do
      assert Artifact.sidecar_name(:media, "20260805-031700") ==
               "kiln-media-20260805-031700.sha256"

      assert Artifact.sidecar_name(:db, "20260805-031700") == "kiln-db-20260805-031700.sha256"
    end

    test "good_name/1 and parse_good_name/1 round-trip (#2219)" do
      stamp = "20260805-031700"
      assert Artifact.good_name(stamp) == "kiln-20260805-031700.good"
      assert {:ok, ^stamp} = Artifact.parse_good_name(Artifact.good_name(stamp))
    end

    test "parse_good_name/1 refuses a bad stamp and anything that is not the marker" do
      for name <- [
            "kiln-foo.good",
            "kiln-2026080-031700.good",
            "kiln-db-20260805-031700.good",
            "kiln-20260805-031700.good.partial",
            "kiln-20260805-031700.keep",
            "kiln-db-20260805-031700.dump"
          ] do
        assert :error = Artifact.parse_good_name(name), name
      end

      assert :error = Artifact.parse_good_name(nil)
      assert :error = Artifact.parse_file(Artifact.good_name("20260805-031700"))
      assert :error = Artifact.parse_sidecar_name(Artifact.good_name("20260805-031700"))
      assert :error = Artifact.parse_keep_name(Artifact.good_name("20260805-031700"))
    end

    test "hold_name/1 and parse_hold_name/1 round-trip (#2219)" do
      stamp = "20260805-031700"
      assert Artifact.hold_name(stamp) == "kiln-20260805-031700.hold"
      assert {:ok, ^stamp} = Artifact.parse_hold_name(Artifact.hold_name(stamp))
    end

    test "parse_hold_name/1 refuses a bad stamp and anything that is not the marker" do
      for name <- [
            "kiln-foo.hold",
            "kiln-2026080-031700.hold",
            "kiln-db-20260805-031700.hold",
            "kiln-20260805-031700.hold.partial",
            "kiln-20260805-031700.good",
            "kiln-20260805-031700.keep",
            "kiln-db-20260805-031700.dump"
          ] do
        assert :error = Artifact.parse_hold_name(name), name
      end

      hold = Artifact.hold_name("20260805-031700")
      assert :error = Artifact.parse_hold_name(nil)
      assert :error = Artifact.parse_file(hold)
      assert :error = Artifact.parse_sidecar_name(hold)
      assert :error = Artifact.parse_keep_name(hold)
      assert :error = Artifact.parse_good_name(hold)
    end

    test "files/1 is the name for a single file and the part names, in order, for a set" do
      assert Artifact.files(%{name: "kiln-db-x.dump", parts: []}) == ["kiln-db-x.dump"]

      assert Artifact.files(%{
               name: "kiln-media-20260805-031700",
               parts: [%{"name" => "b.tar.gz"}, %{"name" => "a.tar.gz"}]
             }) == ["b.tar.gz", "a.tar.gz"]
    end
  end

  describe "from_manifest/2 with checksums and parts (#2218)" do
    @hex String.duplicate("ab", 32)

    test "carries a valid sha256, part and parts_total" do
      assert {:ok, attrs} =
               Artifact.from_manifest(%{
                 kind: "media",
                 path: "media/kiln-media-20260805-031700.part02.tar.gz",
                 bytes: 5,
                 verified: true,
                 sha256: String.upcase(@hex),
                 part: 2,
                 parts_total: 3
               })

      assert %{sha256: @hex, part: 2, parts_total: 3} = attrs
    end

    test "drops invalid values instead of storing them" do
      assert {:ok, attrs} =
               Artifact.from_manifest(%{
                 kind: "db",
                 path: "db/a.dump",
                 bytes: 1,
                 sha256: "not-hex",
                 part: 0,
                 parts_total: "3"
               })

      refute Map.has_key?(attrs, :sha256)
      refute Map.has_key?(attrs, :part)
      refute Map.has_key?(attrs, :parts_total)
    end
  end

  describe "group_files/1 (#2218)" do
    defp flat(name, part, extra \\ %{}) do
      Map.merge(
        %{
          kind: :media,
          name: name,
          bytes: 10,
          verified: true,
          sha256: @hex,
          part: part,
          parts_total: 3,
          destinations: %{"local" => %{"status" => "ok"}}
        },
        extra
      )
    end

    test "folds the parts of one stamp into one artifact, in numeric order" do
      stamp = "20260805-031700"
      names = for n <- [100, 2, 10, 1], do: Artifact.part_name(stamp, n)

      entries = Enum.zip_with(names, [100, 2, 10, 1], &flat(&1, &2))

      assert [artifact] = Artifact.group_files(entries)
      assert artifact.name == "kiln-media-#{stamp}"
      assert artifact.kind == :media
      assert artifact.bytes == 40
      assert artifact.verified
      assert artifact.sha256 == nil

      assert Enum.map(artifact.parts, & &1["name"]) ==
               Enum.map([1, 2, 10, 100], &Artifact.part_name(stamp, &1))

      assert Enum.all?(artifact.parts, &(&1["sha256"] == @hex and &1["bytes"] == 10))
    end

    test "verified only when every part is; destinations only when every part reached them" do
      stamp = "20260805-031700"

      entries = [
        flat(Artifact.part_name(stamp, 1), 1, %{
          destinations: %{"local" => %{"status" => "ok"}, "rclone:r" => %{"status" => "ok"}}
        }),
        flat(Artifact.part_name(stamp, 2), 2, %{verified: false})
      ]

      assert [artifact] = Artifact.group_files(entries)
      refute artifact.verified
      assert Map.keys(artifact.destinations) == ["local"]
    end

    test "the grouped artifact is accepted by the embedded create action" do
      stamp = "20260805-031700"
      entries = [flat(Artifact.part_name(stamp, 1), 1), flat(Artifact.part_name(stamp, 2), 2)]
      assert [attrs] = Artifact.group_files(entries)

      assert {:ok, artifact} =
               Artifact |> Ash.Changeset.for_create(:create, attrs) |> Ash.create()

      assert length(artifact.parts) == 2
    end

    test "legacy single files and db dumps pass through, with manifest-only keys dropped" do
      single = flat("kiln-media-20260805-031700.tar.gz", 1, %{parts_total: 1})

      db = %{
        kind: :db,
        name: "kiln-db-20260805-031700.dump",
        bytes: 3,
        verified: true,
        sha256: @hex
      }

      assert [a, b] = Artifact.group_files([single, db])
      assert a.name == "kiln-media-20260805-031700.tar.gz"
      refute Map.has_key?(a, :part)
      refute Map.has_key?(a, :parts_total)
      assert a.sha256 == @hex
      assert b == db

      assert {:ok, _} = Artifact |> Ash.Changeset.for_create(:create, a) |> Ash.create()
    end

    test "different stamps stay separate and first-seen order is kept" do
      a1 = flat(Artifact.part_name("20260805-031700", 1), 1)
      b1 = flat(Artifact.part_name("20260806-031700", 1), 1)
      a2 = flat(Artifact.part_name("20260805-031700", 2), 2)

      assert [%{name: "kiln-media-20260805-031700"}, %{name: "kiln-media-20260806-031700"}] =
               Artifact.group_files([a1, b1, a2])
    end

    test "a lone .partNN file (the rest missing) is still a one-part set, not a legacy file" do
      lone = flat(Artifact.part_name("20260805-031700", 2), 2)
      assert [%{name: "kiln-media-20260805-031700", parts: [_]}] = Artifact.group_files([lone])
    end
  end

  describe "destinations validation" do
    defp create_with(destinations) do
      Artifact
      |> Ash.Changeset.for_create(:create, %{
        kind: :db,
        name: "a.dump",
        destinations: destinations
      })
      |> Ash.create()
    end

    test "local is accepted" do
      assert {:ok, _} = create_with(%{"local" => %{"status" => "ok"}})
    end

    test "an rclone remote is accepted" do
      assert {:ok, _} = create_with(%{"rclone:r2:bucket" => %{"status" => "failed"}})
    end

    test "a stored destination's dest:<uuid> is accepted (#2220)" do
      key = "dest:" <> Ash.UUID.generate()
      assert {:ok, %{destinations: %{^key => _}}} = create_with(%{key => %{"status" => "ok"}})
    end

    test "dest: with anything but a canonical uuid is refused (#2220)" do
      upper = "dest:" <> String.upcase(Ash.UUID.generate())

      for key <- ["dest:not-a-uuid", "dest:", upper, "dest:" <> Ash.UUID.generate() <> "/x"] do
        assert {:error, _} = create_with(%{key => %{"status" => "ok"}}), key
      end
    end

    test "dest:<uuid> with an unknown status is refused" do
      assert {:error, _} =
               create_with(%{("dest:" <> Ash.UUID.generate()) => %{"status" => "meh"}})
    end

    test "an unknown prefix is refused" do
      for key <- ["s3:bucket", "unreadable", "Local"] do
        assert {:error, _} = create_with(%{key => %{"status" => "ok"}}), key
      end
    end

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

  # What `Verify` and a download (part of #2225) may join to a path.
  describe "checked_files/2" do
    @stamp "20261118-031700"

    defp artifact(attrs), do: struct(Artifact, Map.merge(%{destinations: %{}, parts: []}, attrs))

    test "a single file: its name, lowercase digest, size and destinations" do
      dests = %{"local" => %{"status" => "ok"}}

      assert {:ok, [file]} =
               Artifact.checked_files(
                 artifact(%{
                   kind: :db,
                   name: "kiln-db-#{@stamp}.dump",
                   bytes: 3,
                   sha256: String.duplicate("A", 64),
                   destinations: dests
                 }),
                 @stamp
               )

      assert file == %{
               name: "kiln-db-#{@stamp}.dump",
               sha256: String.duplicate("a", 64),
               bytes: 3,
               destinations: dests
             }
    end

    test "a set's parts in order, each with its own destinations or the set's" do
      own = %{"local" => %{"status" => "pruned"}}
      set = %{"local" => %{"status" => "ok"}}
      [one, two] = Artifact.set_names(@stamp, 2)

      assert {:ok, [first, second]} =
               Artifact.checked_files(
                 artifact(%{
                   kind: :media,
                   name: "kiln-media-#{@stamp}",
                   destinations: set,
                   parts: [
                     %{"name" => one, "bytes" => 1, "destinations" => own},
                     %{name: two, bytes: 2, sha256: "not a digest"}
                   ]
                 }),
                 @stamp
               )

      assert %{name: ^one, bytes: 1, destinations: ^own, sha256: nil} = first
      assert %{name: ^two, bytes: 2, destinations: ^set} = second
    end

    test "a set of one may keep the legacy name" do
      legacy = "kiln-media-#{@stamp}.tar.gz"

      assert {:ok, [%{name: ^legacy}]} =
               Artifact.checked_files(
                 artifact(%{
                   kind: :media,
                   name: "kiln-media-#{@stamp}",
                   parts: [%{"name" => legacy}]
                 }),
                 @stamp
               )
    end

    test "refuses any name that isn't a bare file of this stamp and kind, in order" do
      [one, two] = Artifact.set_names(@stamp, 2)

      for bad <- [
            artifact(%{kind: :db, name: "../kiln-db-#{@stamp}.dump"}),
            artifact(%{kind: :db, name: "db/kiln-db-#{@stamp}.dump"}),
            artifact(%{kind: :db, name: "kiln-db-20261117-031700.dump"}),
            artifact(%{kind: :db, name: "kiln-db-#{@stamp}.dump.partial"}),
            artifact(%{kind: :db, name: "kiln-db-#{@stamp}.dump.4821-2.partial"}),
            artifact(%{kind: :db, name: "kiln-media-#{@stamp}.tar.gz"}),
            artifact(%{kind: :media, name: "x", parts: [%{"name" => two}, %{"name" => one}]}),
            artifact(%{
              kind: :media,
              name: "x",
              parts: [%{"name" => "kiln-media-#{@stamp}.part1.tar.gz"}]
            }),
            artifact(%{kind: :media, name: "x", parts: [%{"name" => one}, %{"bytes" => 1}]}),
            artifact(%{kind: :media, name: "x", parts: [%{"name" => one}, "not a map"]})
          ] do
        assert {:error, detail} = Artifact.checked_files(bad, @stamp)
        assert detail =~ "nothing was read"
      end
    end

    test "pruned_here?/2: the file's own local marker, else the artifact's" do
      pruned = %{"local" => %{"status" => "pruned"}}
      ok = %{"local" => %{"status" => "ok"}}

      assert Artifact.pruned_here?(%{destinations: pruned}, %{destinations: ok})
      refute Artifact.pruned_here?(%{destinations: ok}, %{destinations: pruned})

      assert Artifact.pruned_here?(%{destinations: %{"dest:x" => ok["local"]}}, %{
               destinations: pruned
             })

      assert Artifact.pruned_here?(%{destinations: nil}, %{destinations: pruned})
      refute Artifact.pruned_here?(%{destinations: nil}, %{destinations: %{}})
    end
  end
end
