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

    # Source is 1200px wide: both targets (400, 1024) are smaller, so both run.
    by_label = Map.new(variants, &{&1.label, &1})
    assert Map.keys(by_label) |> Enum.sort() == ["medium", "thumb"]

    assert by_label["thumb"].width == 400
    assert by_label["medium"].width == 1024
    assert File.exists?(by_label["thumb"].path)

    Enum.each(variants, &File.rm(&1.path))
  end

  test "validate_upload/1 accepts a readable raster image", %{path: path} do
    assert {:ok, %{ext: ".png", content_type: "image/png"}} = ImageProcessor.validate_upload(path)
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

    assert {:ok, %{width: 150, variants: []}} = ImageProcessor.process(small, ".png")

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
