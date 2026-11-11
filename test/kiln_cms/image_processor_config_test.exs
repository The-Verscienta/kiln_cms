defmodule KilnCMS.ImageProcessorConfigTest do
  @moduledoc """
  `KilnCMS.ImageProcessor` under configuration (#473, #215): variant formats,
  encoder quality and the decompression-bomb pixel cap.

  Split out of `KilnCMS.ImageProcessorTest` and `async: false` because each
  test rewrites `:image_variants` or `:media`, which are VM-global and read on
  every upload: while these ran async, a concurrent test uploading an image
  could get the wrong variants or a `:too_many_pixels` refusal (#2380).
  """
  use ExUnit.Case, async: false

  alias KilnCMS.ImageProcessor

  setup do
    path = Path.join(System.tmp_dir!(), "ip-#{System.unique_integer([:positive])}.png")
    {:ok, image} = Image.new(1200, 800, color: :blue)
    {:ok, _} = Image.write(image, path)
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  # Restores whatever was configured before, not merely deletes it.
  defp put_config(key, value) do
    previous = Application.fetch_env(:kiln_cms, key)
    Application.put_env(:kiln_cms, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:kiln_cms, key, old)
        :error -> Application.delete_env(:kiln_cms, key)
      end
    end)
  end

  describe "modern formats (#473)" do
    test "an unconfigured format list writes the source format only", %{path: path} do
      put_config(:image_variants, formats: [])

      {:ok, %{variants: variants}} = ImageProcessor.process(path, ".png")

      assert variants |> Enum.map(& &1.label) |> Enum.sort() == ["card", "medium", "thumb"]

      Enum.each(variants, &File.rm(&1.path))
    end

    test "an unknown configured format is dropped rather than raising" do
      put_config(:image_variants, formats: [:webp, :jxl])

      assert ImageProcessor.variant_formats() == [:webp]
    end

    # `Image.write` rejects a quality outside 1..100, and a rejected write
    # produces no variant at all — so an unclamped `System.get_env/1` string
    # would empty the library rather than degrade one format.
    test "a misconfigured quality falls back instead of failing every write", %{path: path} do
      put_config(:image_variants, webp_quality: "82")

      assert ImageProcessor.quality(:webp) == 82

      {:ok, %{variants: variants}} = ImageProcessor.process(path, ".png")
      assert Enum.any?(variants, &(&1.label == "thumb.webp"))

      Enum.each(variants, &File.rm(&1.path))
    end

    test "quality is configurable per format, with a default" do
      assert ImageProcessor.quality(:webp) == 82

      put_config(:image_variants, webp_quality: 60)

      assert ImageProcessor.quality(:webp) == 60
    end
  end

  # Decompression-bomb guard: dimensions above the configured pixel budget are
  # rejected from the header alone, before any full decode can happen.
  test "validate_upload/1 rejects images above the pixel limit", %{path: path} do
    put_config(:media, max_pixels: 100)

    # The fixture is 1200x800 (960k pixels) — far over a 100-pixel budget.
    assert {:error, :too_many_pixels} = ImageProcessor.validate_upload(path)
  end
end
