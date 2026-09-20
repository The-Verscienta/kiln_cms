defmodule KilnCMS.Media.DerivativesTest do
  @moduledoc """
  The derivative cache and the render behind it: real libvips output at the
  planned size and format, kept once and read back after, bounded by the
  per-item budget, pruned when the item's original or focal point moves, and
  findable for a purge.
  """
  # async: false — points Storage.Local and `:image_transforms` at test values
  # via the global app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.{CMS, ImageProcessor, Storage, SystemActor}
  alias KilnCMS.Media.{Derivatives, ImageTransform}

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_tx_#{System.unique_integer([:positive])}")
    private_root = root <> "_private"
    File.mkdir_p!(root)
    File.mkdir_p!(private_root)

    Application.put_env(:kiln_cms, KilnCMS.Storage.Local,
      root: root,
      private_root: private_root,
      base_url: "/uploads"
    )

    previous = Application.get_env(:kiln_cms, :image_transforms)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(private_root)
      Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)

      if previous,
        do: Application.put_env(:kiln_cms, :image_transforms, previous),
        else: Application.delete_env(:kiln_cms, :image_transforms)
    end)

    %{root: root, private_root: private_root}
  end

  defp stored_image(width, height, opts \\ []) do
    ext = Keyword.get(opts, :ext, ".png")
    src = Path.join(System.tmp_dir!(), "tx-src-#{System.unique_integer([:positive])}#{ext}")
    {:ok, image} = Image.new(width, height, color: Keyword.get(opts, :color, :green))
    {:ok, _} = Image.write(image, src)
    key = "orig-#{System.unique_integer([:positive])}#{ext}"

    {:ok, ^key} =
      if Keyword.get(opts, :private, false),
        do: Storage.store_private(key, src),
        else: Storage.store(key, src)

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
          content_type: "image/png",
          width: 1200,
          height: 800
        },
        attrs
      )
    )
  end

  defp plan!(item, ops, accept \\ nil) do
    {:ok, params} = ImageTransform.parse(ops)
    {:ok, plan} = ImageTransform.plan(item, params, accept)
    plan
  end

  defp rows(item) do
    CMS.list_media_derivatives!(item.id,
      actor: SystemActor.new(:test),
      tenant: item.org_id
    )
  end

  describe "ImageProcessor.render/3" do
    test "crops and resizes to exactly the planned size, in the planned format" do
      item = media_item(stored_image(1200, 800))
      plan = plan!(item, "w_640,ar_16:9,fm_webp")

      assert {:ok, bytes} = Derivatives.render(item, plan)
      {:ok, image} = Image.from_binary(bytes)
      assert {Image.width(image), Image.height(image)} == {640, 360}
      assert {:ok, "webpload" <> _} = Vix.Vips.Image.header_value(image, "vips-loader")
    end

    test "flattens transparency onto white for JPEG" do
      src = Path.join(System.tmp_dir!(), "alpha-#{System.unique_integer([:positive])}.png")
      {:ok, image} = Image.new(40, 40, color: [0, 0, 0, 0])
      {:ok, _} = Image.write(image, src)

      assert {:ok, %{path: out}} =
               ImageProcessor.render(src, %{
                 crop: nil,
                 width: 20,
                 height: 20,
                 format: :jpg,
                 quality: 80,
                 ext: ".jpg"
               })

      {:ok, rendered} = Image.open(out)
      refute Image.has_alpha?(rendered)
      {:ok, [r, g, b]} = Image.get_pixel(rendered, 10, 10)
      assert r > 240 and g > 240 and b > 240

      File.rm(src)
      File.rm(out)
    end

    test "refuses a decoded frame over the pixel cap" do
      src = Path.join(System.tmp_dir!(), "big-#{System.unique_integer([:positive])}.png")
      {:ok, image} = Image.new(100, 100, color: :green)
      {:ok, _} = Image.write(image, src)

      spec = %{crop: nil, width: 10, height: 10, format: :png, quality: nil, ext: ".png"}
      assert {:error, :too_many_pixels} = ImageProcessor.render(src, spec, max_pixels: 9_999)
      File.rm(src)
    end
  end

  describe "the cache" do
    test "a render is kept, and the next lookup reads it back", %{root: root} do
      item = media_item(stored_image(1200, 800))
      plan = plan!(item, "w_640")

      assert Derivatives.lookup(item, plan) == :miss
      assert {:ok, rendered} = Derivatives.render(item, plan)
      assert {:ok, ^rendered} = Derivatives.lookup(item, plan)
      assert File.exists?(Path.join(root, Derivatives.storage_key(plan)))

      assert [row] = rows(item)
      assert row.storage_key == Derivatives.storage_key(plan)
      assert row.source_key == item.storage_key
      assert {row.width, row.height} == {640, 427}
      assert row.byte_size == byte_size(rendered)
      refute row.private
    end

    test "rendering the same derivative twice keeps one row" do
      item = media_item(stored_image(1200, 800))
      plan = plan!(item, "w_640")
      {:ok, _} = Derivatives.render(item, plan)

      # A second render of an already-kept derivative is served from the cache
      # inside the gate, without rendering or recording again.
      {:ok, _} = Derivatives.render(item, plan)
      assert length(rows(item)) == 1
    end

    test "past the per-item budget a transform is served but not kept", %{root: root} do
      Application.put_env(:kiln_cms, :image_transforms, max_derivatives_per_item: 1)
      item = media_item(stored_image(1200, 800))

      {:ok, _} = Derivatives.render(item, plan!(item, "w_640"))
      over = plan!(item, "w_256")
      assert {:ok, bytes} = Derivatives.render(item, over)
      assert byte_size(bytes) > 0

      assert length(rows(item)) == 1
      refute File.exists?(Path.join(root, Derivatives.storage_key(over)))
      assert Derivatives.lookup(item, over) == :miss
    end

    test "derivatives of a replaced original are pruned before the budget is counted", %{
      root: root
    } do
      Application.put_env(:kiln_cms, :image_transforms, max_derivatives_per_item: 1)
      item = media_item(stored_image(1200, 800))
      old = plan!(item, "w_640")
      {:ok, _} = Derivatives.render(item, old)

      rotated_key = stored_image(800, 1200)

      {:ok, rotated} =
        CMS.update_media_item(
          item,
          %{storage_key: rotated_key, url: "/uploads/#{rotated_key}", width: 800, height: 1200},
          authorize?: false
        )

      new = plan!(rotated, "w_640")
      {:ok, _} = Derivatives.render(rotated, new)

      assert [row] = rows(rotated)
      assert row.source_key == rotated_key
      refute File.exists?(Path.join(root, Derivatives.storage_key(old)))
      assert File.exists?(Path.join(root, Derivatives.storage_key(new)))
    end

    test "a moved focal point prunes focal crops but keeps plain resizes", %{root: root} do
      item = media_item(stored_image(1200, 800))
      resize = plan!(item, "w_640")
      crop = plan!(item, "w_256,h_256")
      {:ok, _} = Derivatives.render(item, resize)
      {:ok, _} = Derivatives.render(item, crop)

      {:ok, moved} = CMS.update_media_item(item, %{focal_x: 0.1}, authorize?: false)
      {:ok, _} = Derivatives.render(moved, plan!(moved, "w_128"))

      keys = moved |> rows() |> Enum.map(& &1.storage_key) |> MapSet.new()
      assert Derivatives.storage_key(resize) in keys
      refute Derivatives.storage_key(crop) in keys
      refute File.exists?(Path.join(root, Derivatives.storage_key(crop)))
    end

    test "an item outside the public audience keeps its derivatives in private storage", %{
      root: root,
      private_root: private_root
    } do
      key = stored_image(1200, 800, private: true)
      item = media_item(key, %{audience: :member})
      plan = plan!(item, "w_640")

      assert {:ok, _} = Derivatives.render(item, plan)
      assert File.exists?(Path.join(private_root, Derivatives.storage_key(plan)))
      refute File.exists?(Path.join(root, Derivatives.storage_key(plan)))
      assert [%{private: true}] = rows(item)
      assert {:ok, _} = Derivatives.lookup(item, plan)
    end

    test "blobs/1 lists the kept derivatives and delete_blobs/1 removes them", %{root: root} do
      item = media_item(stored_image(1200, 800))
      plan = plan!(item, "w_640")
      {:ok, _} = Derivatives.render(item, plan)

      assert [{key, false}] = Derivatives.blobs(item)
      assert key == Derivatives.storage_key(plan)

      Derivatives.delete_blobs(Derivatives.blobs(item))
      refute File.exists?(Path.join(root, key))
    end

    test "an original that can't be read is an error, not a crash" do
      item = media_item("missing-#{System.unique_integer([:positive])}.png")
      assert {:error, _} = Derivatives.render(item, plan!(item, "w_640"))
      assert rows(item) == []
    end
  end
end
