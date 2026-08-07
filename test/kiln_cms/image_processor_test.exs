defmodule KilnCMS.ImageProcessorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias KilnCMS.ImageProcessor

  setup do
    path = Path.join(System.tmp_dir!(), "ip-#{System.unique_integer([:positive])}.png")
    {:ok, image} = Image.new(1200, 800, color: :blue)
    {:ok, _} = Image.write(image, path)
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "reads the intrinsic dimensions", %{path: path} do
    assert {:ok, %{width: 1200, height: 800}} = ImageProcessor.process(path, ".png")
  end

  test "generates downscaled variants and never upscales", %{path: path} do
    {:ok, %{variants: variants}} = ImageProcessor.process(path, ".png")

    # Source is 1200px wide: both targets (400, 1024) are smaller, so both
    # run — plus the focal-aware 16:9 card crop (source covers 800×450). Each
    # is written in the source format (bare label) and in every configured
    # alternate (`<label>.<format>`, WebP by default).
    by_label = Map.new(variants, &{&1.label, &1})

    assert Map.keys(by_label) |> Enum.sort() ==
             [
               "card",
               "card.webp",
               "full.webp",
               "medium",
               "medium.webp",
               "thumb",
               "thumb.webp"
             ]

    assert by_label["thumb"].width == 400
    assert by_label["medium"].width == 1024
    assert by_label["card"].width == 800
    assert by_label["card"].height == 450
    assert File.exists?(by_label["thumb"].path)

    Enum.each(variants, &File.rm(&1.path))
  end

  describe "modern formats (#473)" do
    test "each variant is written in the source format and every alternate", %{path: path} do
      {:ok, %{variants: variants}} = ImageProcessor.process(path, ".png")
      by_label = Map.new(variants, &{&1.label, &1})

      # The bare label is the `<img src>` fallback, in the source's own format.
      assert by_label["thumb"].content_type == "image/png"
      assert by_label["thumb"].ext == ".png"

      # …and the alternate carries the type a `<picture>` `<source>` needs.
      assert by_label["thumb.webp"].content_type == "image/webp"
      assert by_label["thumb.webp"].ext == ".webp"
      assert File.exists?(by_label["thumb.webp"].path)

      # Same pixels, different encoding.
      assert by_label["thumb.webp"].width == by_label["thumb"].width
      assert by_label["thumb.webp"].height == by_label["thumb"].height

      Enum.each(variants, &File.rm(&1.path))
    end

    test "a WebP source is written once, not twice under two keys" do
      path = Path.join(System.tmp_dir!(), "ip-#{System.unique_integer([:positive])}.webp")
      {:ok, image} = Image.new(1200, 800, color: :blue)
      {:ok, _} = Image.write(image, path)
      on_exit(fn -> File.rm(path) end)

      {:ok, %{variants: variants}} = ImageProcessor.process(path, ".webp")
      labels = variants |> Enum.map(& &1.label) |> Enum.sort()

      assert labels == ["card", "medium", "thumb"]
      assert Enum.all?(variants, &(&1.content_type == "image/webp"))

      Enum.each(variants, &File.rm(&1.path))
    end

    test "an unconfigured format list writes the source format only", %{path: path} do
      Application.put_env(:kiln_cms, :image_variants, formats: [])
      on_exit(fn -> Application.delete_env(:kiln_cms, :image_variants) end)

      {:ok, %{variants: variants}} = ImageProcessor.process(path, ".png")

      assert variants |> Enum.map(& &1.label) |> Enum.sort() == ["card", "medium", "thumb"]

      Enum.each(variants, &File.rm(&1.path))
    end

    test "an unknown configured format is dropped rather than raising" do
      Application.put_env(:kiln_cms, :image_variants, formats: [:webp, :jxl])
      on_exit(fn -> Application.delete_env(:kiln_cms, :image_variants) end)

      assert ImageProcessor.variant_formats() == [:webp]
    end

    # A matching `<source>` REPLACES the `<img>`'s srcset, so without a
    # full-size alternate a WebP-capable browser could never reach a candidate
    # wider than the largest downscale — every image would quietly render
    # smaller than it did before.
    test "a full-size alternate is written so <picture> can reach the original width", %{
      path: path
    } do
      {:ok, %{width: width, variants: variants}} = ImageProcessor.process(path, ".png")
      by_label = Map.new(variants, &{&1.label, &1})

      assert by_label["full.webp"].width == width
      assert by_label["full.webp"].content_type == "image/webp"

      # …and no source-format `full`: that is the original, which
      # `Presentation.srcset/1` already appends.
      refute Map.has_key?(by_label, "full")

      Enum.each(variants, &File.rm(&1.path))
    end

    # `Image.write` rejects a quality outside 1..100, and a rejected write
    # produces no variant at all — so an unclamped `System.get_env/1` string
    # would empty the library rather than degrade one format.
    test "a misconfigured quality falls back instead of failing every write", %{path: path} do
      Application.put_env(:kiln_cms, :image_variants, webp_quality: "82")
      on_exit(fn -> Application.delete_env(:kiln_cms, :image_variants) end)

      assert ImageProcessor.quality(:webp) == 82

      {:ok, %{variants: variants}} = ImageProcessor.process(path, ".png")
      assert Enum.any?(variants, &(&1.label == "thumb.webp"))

      Enum.each(variants, &File.rm(&1.path))
    end

    test "quality is configurable per format, with a default" do
      assert ImageProcessor.quality(:webp) == 82

      Application.put_env(:kiln_cms, :image_variants, webp_quality: 60)
      on_exit(fn -> Application.delete_env(:kiln_cms, :image_variants) end)

      assert ImageProcessor.quality(:webp) == 60
    end

    test "base_label/1 sees through the format suffix" do
      assert ImageProcessor.base_label("card") == "card"
      assert ImageProcessor.base_label("card.webp") == "card"
      assert ImageProcessor.base_label("card.avif") == "card"
    end

    test "variant_content_type/1 reads the suffix, and is nil for a bare label" do
      assert ImageProcessor.variant_content_type("thumb.webp") == "image/webp"
      assert ImageProcessor.variant_content_type("thumb.avif") == "image/avif"
      assert ImageProcessor.variant_content_type("thumb") == nil
      assert ImageProcessor.variant_content_type("thumb.jxl") == nil
    end
  end

  describe "focal-aware card crop" do
    # An 800×800 image, black except a white square at the very top. A 16:9
    # card crop of a square source keeps the full width and crops vertically —
    # so where the window lands shows up as brightness (the mark in or out).
    defp marked_image do
      path = Path.join(System.tmp_dir!(), "focal-#{System.unique_integer([:positive])}.png")
      {:ok, base} = Image.new(800, 800, color: :black)
      {:ok, mark} = Image.new(120, 120, color: :white)
      {:ok, marked} = Image.compose(base, mark, x: 340, y: 0)
      {:ok, _} = Image.write(marked, path)
      path
    end

    defp average_brightness(path) do
      {:ok, image} = Image.open(path)
      image |> Image.average() |> List.first() |> round()
    end

    test "the crop window follows the focal point (clamped to the bounds)" do
      path = marked_image()
      on_exit(fn -> File.rm(path) end)

      # Focal on the top mark (clamped to the top edge)…
      {:ok, %{variants: focused}} = ImageProcessor.process(path, ".png", %{x: 0.5, y: 0.05})
      # …vs the default center, whose 450px window (175..625) misses the mark.
      {:ok, %{variants: centered}} = ImageProcessor.process(path, ".png", %{x: 0.5, y: 0.5})

      focused_card = Enum.find(focused, &(&1.label == "card"))
      centered_card = Enum.find(centered, &(&1.label == "card"))

      assert average_brightness(focused_card.path) > average_brightness(centered_card.path)
      assert average_brightness(centered_card.path) == 0

      Enum.each(focused ++ centered, &File.rm(&1.path))
    end

    test "no crop when the source is smaller than the target box" do
      small = Path.join(System.tmp_dir!(), "small-#{System.unique_integer([:positive])}.png")
      {:ok, image} = Image.new(600, 400, color: :red)
      {:ok, _} = Image.write(image, small)
      on_exit(fn -> File.rm(small) end)

      {:ok, %{variants: variants}} = ImageProcessor.process(small, ".png")
      refute Enum.any?(variants, &(&1.label == "card"))

      Enum.each(variants, &File.rm(&1.path))
    end

    test "cropped labels are published for srcset exclusion" do
      assert "card" in ImageProcessor.cropped_labels()
    end
  end

  describe "transform/3" do
    test "rotation swaps the dimensions", %{path: path} do
      assert {:ok, %{path: out, width: 800, height: 1200}} =
               ImageProcessor.transform(path, ".png", :rotate_right)

      assert File.exists?(out)
      File.rm(out)
    end

    test "flips keep the dimensions", %{path: path} do
      assert {:ok, %{path: out, width: 1200, height: 800}} =
               ImageProcessor.transform(path, ".png", :flip_horizontal)

      File.rm(out)
    end

    test "returns an error for non-image input" do
      bad = Path.join(System.tmp_dir!(), "bad-#{System.unique_integer([:positive])}.png")
      File.write!(bad, "not an image")
      on_exit(fn -> File.rm(bad) end)

      assert {:error, _} = ImageProcessor.transform(bad, ".png", :rotate_left)
    end
  end

  test "validate_upload/1 accepts a readable raster image", %{path: path} do
    assert {:ok, %{ext: ".png", content_type: "image/png"}} = ImageProcessor.validate_upload(path)
  end

  # Decompression-bomb guard: dimensions above the configured pixel budget are
  # rejected from the header alone, before any full decode can happen.
  test "validate_upload/1 rejects images above the pixel limit", %{path: path} do
    Application.put_env(:kiln_cms, :media, max_pixels: 100)
    on_exit(fn -> Application.delete_env(:kiln_cms, :media) end)

    # The fixture is 1200x800 (960k pixels) — far over a 100-pixel budget.
    assert {:error, :too_many_pixels} = ImageProcessor.validate_upload(path)
  end

  test "validate_upload/1 derives the extension from bytes, not the filename", %{path: path} do
    # PNG bytes written to a `.svg`-named file: the result must reflect the real
    # format (PNG), so a disguised upload can never be stored with an .svg key.
    evil = Path.join(System.tmp_dir!(), "evil-#{System.unique_integer([:positive])}.svg")
    File.cp!(path, evil)
    on_exit(fn -> File.rm(evil) end)

    assert {:ok, %{ext: ".png", content_type: "image/png"}} = ImageProcessor.validate_upload(evil)
  end

  test "validate_upload/1 rejects a well-formed SVG" do
    svg = Path.join(System.tmp_dir!(), "vector-#{System.unique_integer([:positive])}.svg")

    File.write!(
      svg,
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>)
    )

    on_exit(fn -> File.rm(svg) end)

    assert {:error, _} = ImageProcessor.validate_upload(svg)
  end

  test "validate_upload/1 rejects non-image content" do
    fake = Path.join(System.tmp_dir!(), "fake-#{System.unique_integer([:positive])}.png")
    File.write!(fake, "not an image")
    on_exit(fn -> File.rm(fake) end)

    assert {:error, _} = ImageProcessor.validate_upload(fake)
  end

  test "skips variants wider than the source (no upscaling)" do
    small = Path.join(System.tmp_dir!(), "small-#{System.unique_integer([:positive])}.png")
    {:ok, image} = Image.new(150, 100, color: :red)
    {:ok, _} = Image.write(image, small)

    {:ok, %{width: 150, variants: variants}} = ImageProcessor.process(small, ".png")

    # No downscale and no crop — the source is smaller than every target. The
    # full-size alternate is still written: it is what a `<picture>` `<source>`
    # needs in order to offer this image at its own width in WebP (#473).
    assert Enum.map(variants, & &1.label) == ["full.webp"]
    assert hd(variants).width == 150

    Enum.each(variants, &File.rm(&1.path))
    File.rm(small)
  end

  test "returns an error for non-image files (graceful fallback)" do
    path = Path.join(System.tmp_dir!(), "notimg-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "definitely not an image")

    assert {:error, _} = ImageProcessor.process(path, ".txt")

    File.rm(path)
  end

  describe "strip_metadata/2 (#215)" do
    @artist_field "exif-ifd0-Artist"

    # A JPEG carrying an EXIF Artist tag (stands in for GPS/device metadata).
    defp jpeg_with_exif do
      path = Path.join(System.tmp_dir!(), "exif-#{System.unique_integer([:positive])}.jpg")
      {:ok, image} = Image.new(600, 400, color: :green)

      {:ok, with_exif} =
        Vix.Vips.Image.mutate(image, fn mut ->
          :ok = Vix.Vips.MutableImage.set(mut, @artist_field, :gchararray, "Secret Person")
        end)

      {:ok, _} = Image.write(with_exif, path)
      path
    end

    defp field?(path, field) do
      {:ok, image} = Image.open(path)

      case Vix.Vips.Image.header_value(image, field) do
        {:ok, _value} -> true
        _ -> false
      end
    end

    test "removes EXIF metadata from the re-encoded copy" do
      src = jpeg_with_exif()
      on_exit(fn -> File.rm(src) end)
      # Sanity: the source really does carry the EXIF tag.
      assert field?(src, @artist_field)

      assert {:ok, stripped} = ImageProcessor.strip_metadata(src, ".jpg")
      on_exit(fn -> File.rm(stripped) end)

      # The PII-bearing tag is gone (libvips may regenerate a technical-only
      # exif-data blob on save — resolution/colorspace — but no EXIF Artist/GPS).
      refute field?(stripped, @artist_field)
      refute stripped |> File.read!() |> String.contains?("Secret Person")
      # The pixels survive: same dimensions, still a readable image.
      assert {:ok, %{width: 600, height: 400}} = ImageProcessor.process(stripped, ".jpg")
    end

    test "returns an error for non-image input (caller falls back to original)" do
      bad = Path.join(System.tmp_dir!(), "bad-#{System.unique_integer([:positive])}.jpg")
      File.write!(bad, "not an image")
      on_exit(fn -> File.rm(bad) end)

      assert {:error, _} = ImageProcessor.strip_metadata(bad, ".jpg")
    end
  end
end
