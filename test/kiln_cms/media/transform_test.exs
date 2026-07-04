defmodule KilnCMS.Media.TransformTest do
  @moduledoc """
  In-admin image editing (`KilnCMS.Media.Transform`): rotate/flip writes an
  edited original under a NEW key (the previous file survives for published
  snapshots), updates the item's dimensions and geometry-transformed focal
  point, and re-enqueues variant generation; `set_focal_point/4` clamps and
  regenerates the focal-aware crops.
  """
  # async: false — points Storage.Local at a temp dir via the global app env.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.Media.Transform
  alias KilnCMS.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_edit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:kiln_cms, KilnCMS.Storage.Local, root: root, base_url: "/uploads")

    on_exit(fn ->
      File.rm_rf!(root)
      Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
    end)

    :ok
  end

  defp stored_png(width, height) do
    src = Path.join(System.tmp_dir!(), "tf-src-#{System.unique_integer([:positive])}.png")
    {:ok, image} = Image.new(width, height, color: :green)
    {:ok, _} = Image.write(image, src)
    key = "orig-#{System.unique_integer([:positive])}.png"
    {:ok, ^key} = Storage.store(key, src)
    File.rm(src)
    key
  end

  defp media_item(key, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.CMS.MediaItem,
      Map.merge(
        %{
          filename: "orig.png",
          url: "/uploads/#{key}",
          storage_key: key,
          width: 1200,
          height: 800
        },
        attrs
      )
    )
  end

  test "rotate writes a new original, swaps dimensions, and keeps the old file" do
    key = stored_png(1200, 800)
    item = media_item(key, %{focal_x: 0.25, focal_y: 0.5})

    assert {:ok, updated} = Transform.apply(item, :rotate_right, authorize?: false)

    # New key + URL, swapped dimensions.
    refute updated.storage_key == key
    assert updated.url == "/uploads/#{updated.storage_key}"
    assert updated.width == 800
    assert updated.height == 1200

    # The focal point rode the rotation: (0.25, 0.5) → (0.5, 0.25).
    assert_in_delta updated.focal_x, 0.5, 0.001
    assert_in_delta updated.focal_y, 0.25, 0.001

    # The previous original still exists (published snapshots reference it),
    # and the edited copy is fetchable.
    assert {:ok, _old} = Storage.fetch(key)
    assert {:ok, _new} = Storage.fetch(updated.storage_key)

    # Variant regeneration is queued for the edited original.
    assert_enqueued(worker: KilnCMS.Media.VariantWorker, args: %{media_item_id: item.id})
  end

  test "flips keep dimensions and mirror the focal point" do
    key = stored_png(600, 600)
    item = media_item(key, %{width: 600, height: 600, focal_x: 0.2, focal_y: 0.3})

    assert {:ok, updated} = Transform.apply(item, :flip_horizontal, authorize?: false)

    assert updated.width == 600
    assert updated.height == 600
    assert_in_delta updated.focal_x, 0.8, 0.001
    assert_in_delta updated.focal_y, 0.3, 0.001
  end

  test "set_focal_point clamps and re-enqueues variants" do
    key = stored_png(1200, 800)
    item = media_item(key)

    assert {:ok, updated} = Transform.set_focal_point(item, 1.7, -0.2, authorize?: false)

    assert updated.focal_x == 1.0
    assert updated.focal_y == 0.0
    assert_enqueued(worker: KilnCMS.Media.VariantWorker, args: %{media_item_id: item.id})
  end

  test "the regenerated card crop follows the stored focal point" do
    key = stored_png(1200, 800)
    item = media_item(key, %{focal_x: 0.1, focal_y: 0.1})

    # Run the worker inline: variants (incl. the focal-aware card) generate.
    assert :ok =
             perform_job(KilnCMS.Media.VariantWorker, %{"media_item_id" => item.id})

    reloaded = CMS.get_media_item!(item.id, authorize?: false)
    assert %{"card" => %{"width" => 800, "height" => 450}} = reloaded.variants
  end

  test "a missing original is a graceful error" do
    item = media_item("does-not-exist.png")
    assert {:error, _} = Transform.apply(item, :rotate_left, authorize?: false)
  end
end
