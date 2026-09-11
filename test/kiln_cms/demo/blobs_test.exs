defmodule KilnCMS.Demo.BlobsTest do
  @moduledoc """
  Media blobs across a demo reset (`docs/demo-mode.md`): nothing a visitor does
  deletes a file, and the reset deletes only the demo's own files — never one
  the golden snapshot references.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.Demo.Blobs
  alias KilnCMS.Storage

  setup do
    base = Path.join(System.tmp_dir!(), "kiln_demo_blobs_#{System.unique_integer([:positive])}")
    public = Path.join(base, "public")
    private = Path.join(base, "private")
    Enum.each([public, private], &File.mkdir_p!/1)

    restore = [
      {KilnCMS.Storage, Application.get_env(:kiln_cms, KilnCMS.Storage)},
      {KilnCMS.Storage.Local, Application.get_env(:kiln_cms, KilnCMS.Storage.Local)},
      {KilnCMS.Demo, Application.get_env(:kiln_cms, KilnCMS.Demo)}
    ]

    Application.put_env(:kiln_cms, KilnCMS.Storage, adapter: KilnCMS.Storage.Local)
    Application.put_env(:kiln_cms, KilnCMS.Storage.Local, root: public, private_root: private)

    Application.put_env(:kiln_cms, KilnCMS.Demo,
      enabled: true,
      golden_path: Path.join([base, "demo", "golden.dump"])
    )

    on_exit(fn ->
      Enum.each(restore, fn
        {key, nil} -> Application.delete_env(:kiln_cms, key)
        {key, value} -> Application.put_env(:kiln_cms, key, value)
      end)

      File.rm_rf!(base)
    end)

    %{public: public, private: private}
  end

  defp put!(dir, key), do: File.write!(Path.join(dir, key), "bytes of #{key}")
  defp files(dir), do: dir |> File.ls!() |> Enum.sort()

  describe "Storage in demo mode" do
    test "a delete keeps the file and records the key for the reset", %{public: public} do
      put!(public, "golden-hero.jpg")

      assert Storage.delete("golden-hero.jpg") == :ok
      assert Storage.delete_private("quarantined.mp4") == :ok

      assert files(public) == ["golden-hero.jpg"]
      assert File.read!(Blobs.log_path()) == "golden-hero.jpg\nquarantined.mp4\n"
    end

    test "outside demo mode a delete deletes, and nothing is recorded", %{public: public} do
      Application.put_env(:kiln_cms, KilnCMS.Demo, enabled: false)
      put!(public, "upload.jpg")

      assert Storage.delete("upload.jpg") == :ok

      assert files(public) == []
      refute File.exists?(Blobs.log_path())
    end
  end

  describe "reap/2" do
    test "deletes what the demo created and nothing the golden state references",
         %{public: public, private: private} do
      # golden.jpg          — referenced before and after: kept
      # golden-purged.jpg   — a visitor purged a golden image: deferred, but golden
      # visitor.jpg         — a visitor's upload, still referenced at reset time
      # rotated-old.jpg     — an old variant a visitor's rotate replaced: deferred
      # quarantined.mp4     — a private upload whose row was purged: deferred
      Enum.each(~w(golden.jpg golden-purged.jpg visitor.jpg rotated-old.jpg), &put!(public, &1))
      put!(private, "quarantined.mp4")
      Enum.each(~w(golden-purged.jpg rotated-old.jpg quarantined.mp4), &Blobs.defer/1)

      dirty = MapSet.new(~w(golden.jpg visitor.jpg))
      golden = MapSet.new(~w(golden.jpg golden-purged.jpg))

      assert Blobs.reap(dirty, golden) == %{deleted: 3, failed: 0}

      assert files(public) == ["golden-purged.jpg", "golden.jpg"]
      assert files(private) == []
      refute File.exists?(Blobs.log_path())
    end

    test "with nothing to do, does nothing" do
      assert Blobs.reap(MapSet.new(), MapSet.new()) == %{deleted: 0, failed: 0}
    end
  end

  describe "referenced_keys/0" do
    test "names every original and derived file, trashed rows included" do
      Ash.Seed.seed!(MediaItem, %{
        filename: "a.png",
        url: "/uploads/orig-a.png",
        storage_key: "orig-a.png",
        variants: %{
          "small" => %{"key" => "small-a.webp", "url" => "/uploads/small-a.webp"},
          "poster" => %{"key" => "poster-a.jpg"},
          "odd" => "not-an-object"
        }
      })

      # An external item: no key of its own, and a variant without one.
      Ash.Seed.seed!(MediaItem, %{
        filename: "b.png",
        url: "https://images.example/b.png",
        variants: %{"card" => %{"url" => "https://images.example/b-card.png"}}
      })

      # In the trash: its file is still referenced — a restore from trash needs it.
      Ash.Seed.seed!(MediaItem, %{
        filename: "trashed.png",
        url: "/uploads/trashed.png",
        storage_key: "trashed.png",
        archived_at: DateTime.utc_now()
      })

      assert Blobs.referenced_keys() ==
               {:ok, MapSet.new(~w(orig-a.png small-a.webp poster-a.jpg trashed.png))}
    end
  end
end
