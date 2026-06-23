defmodule KilnCMS.Media.VariantWorkerTest do
  @moduledoc """
  The background worker re-fetches the stored original (`Storage.fetch/1`),
  generates + stores responsive variants, writes the dimensions/variant map back
  onto the MediaItem, and broadcasts so the library can refresh.
  """
  # async: false — points Storage.Local at a temp dir via the global app env.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.Media.VariantWorker
  alias KilnCMS.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_variants_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:kiln_cms, KilnCMS.Storage.Local, root: root, base_url: "/uploads")

    on_exit(fn ->
      File.rm_rf!(root)
      Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
    end)

    %{root: root}
  end

  # Write `content` to a temp file, store it under a fresh key, return the key.
  defp store(write_fun, ext) do
    src = Path.join(System.tmp_dir!(), "vw-src-#{System.unique_integer([:positive])}#{ext}")
    write_fun.(src)
    key = "orig-#{System.unique_integer([:positive])}#{ext}"
    {:ok, ^key} = Storage.store(key, src)
    File.rm(src)
    key
  end

  defp store_png(width, height) do
    store(
      fn path ->
        {:ok, image} = Image.new(width, height, color: :green)
        {:ok, _} = Image.write(image, path)
      end,
      ".png"
    )
  end

  defp media_item(key) do
    Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
      filename: "orig.png",
      url: "/uploads/#{key}",
      storage_key: key
    })
  end

  test "fetches the original, stores variants, writes dimensions, broadcasts", %{root: root} do
    item = media_item(store_png(1200, 800))
    Phoenix.PubSub.subscribe(KilnCMS.PubSub, VariantWorker.topic())

    assert :ok = perform_job(VariantWorker, %{media_item_id: item.id})

    reloaded = CMS.get_media_item!(item.id, authorize?: false)
    assert reloaded.width == 1200
    assert reloaded.height == 800

    # Both responsive targets (400, 1024) are smaller than the 1200px source.
    assert %{"thumb" => thumb, "medium" => medium} = reloaded.variants
    assert thumb["width"] == 400
    assert medium["width"] == 1024
    assert File.exists?(Path.join(root, thumb["key"]))
    assert File.exists?(Path.join(root, medium["key"]))

    assert_receive {:media_processed, processed_id}
    assert processed_id == item.id
  end

  test "is a graceful no-op for a non-raster original" do
    item = media_item(store(&File.write!(&1, "not an image"), ".txt"))

    assert :ok = perform_job(VariantWorker, %{media_item_id: item.id})

    reloaded = CMS.get_media_item!(item.id, authorize?: false)
    assert reloaded.width == nil
    assert reloaded.variants == %{}
  end

  test "discards the job when the MediaItem is gone" do
    assert :ok = perform_job(VariantWorker, %{media_item_id: Ecto.UUID.generate()})
  end

  test "is a no-op when the stored original is missing" do
    # MediaItem points at a key that was never stored.
    item = media_item("orig-#{System.unique_integer([:positive])}.png")

    assert :ok = perform_job(VariantWorker, %{media_item_id: item.id})
    assert CMS.get_media_item!(item.id, authorize?: false).variants == %{}
  end
end
