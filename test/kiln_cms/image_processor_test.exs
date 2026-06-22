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
end
