defmodule KilnCMS.Media.VariantWorkerTest do
  @moduledoc """
  The background worker reads an uploaded original, generates + stores responsive
  variants, and writes the dimensions/variant map back onto the MediaItem.
  """
  # async: false — points Storage.Local at a temp dir via the global app env.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.Media.VariantWorker

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

  defp png(width, height) do
    path = Path.join(System.tmp_dir!(), "vw-#{System.unique_integer([:positive])}.png")
    {:ok, image} = Image.new(width, height, color: :green)
    {:ok, _} = Image.write(image, path)
    path
  end

  defp media_item do
    Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
      filename: "orig.png",
      url: "/uploads/orig.png",
      storage_key: "orig.png"
    })
  end

  test "generates and stores variants, writing dimensions back", %{root: root} do
    item = media_item()
    source = png(1200, 800)

    assert :ok =
             perform_job(VariantWorker, %{
               media_item_id: item.id,
               source_path: source,
               ext: ".png"
             })

    reloaded = CMS.get_media_item!(item.id, authorize?: false)
    assert reloaded.width == 1200
    assert reloaded.height == 800

    # Both responsive targets (400, 1024) are smaller than the 1200px source.
    assert %{"thumb" => thumb, "medium" => medium} = reloaded.variants
    assert thumb["width"] == 400
    assert medium["width"] == 1024
    assert File.exists?(Path.join(root, thumb["key"]))
    assert File.exists?(Path.join(root, medium["key"]))

    # The temp source is cleaned up.
    refute File.exists?(source)
  end

  test "is a graceful no-op for a non-raster upload" do
    item = media_item()
    source = Path.join(System.tmp_dir!(), "vw-#{System.unique_integer([:positive])}.txt")
    File.write!(source, "not an image")

    assert :ok =
             perform_job(VariantWorker, %{
               media_item_id: item.id,
               source_path: source,
               ext: ".txt"
             })

    reloaded = CMS.get_media_item!(item.id, authorize?: false)
    assert reloaded.width == nil
    assert reloaded.variants == %{}
    refute File.exists?(source)
  end

  test "discards the job (and temp file) when the MediaItem is gone" do
    source = png(1200, 800)

    assert :ok =
             perform_job(VariantWorker, %{
               media_item_id: Ecto.UUID.generate(),
               source_path: source,
               ext: ".png"
             })

    refute File.exists?(source)
  end
end
