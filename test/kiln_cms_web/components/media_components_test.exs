defmodule KilnCMSWeb.MediaComponentsTest do
  # async: false — builds signed URLs under a key put in the global app env.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Media.ImageTransform
  alias KilnCMSWeb.MediaComponents

  setup do
    previous = Application.get_env(:kiln_cms, :image_transforms)
    Application.put_env(:kiln_cms, :image_transforms, signing_key: "component-test-key")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, :image_transforms, previous),
        else: Application.delete_env(:kiln_cms, :image_transforms)
    end)
  end

  defp item(attrs \\ %{}) do
    Map.merge(
      %{
        id: "8a5b8e4e-7b8f-4a57-9a5e-2f3a1c9d0b11",
        url: "/uploads/orig.jpg",
        storage_key: "orig.jpg",
        content_type: "image/jpeg",
        width: 2400,
        height: 1600,
        focal_x: 0.25,
        focal_y: 0.5,
        alt: "A kiln at dusk"
      },
      attrs
    )
  end

  defp img(assigns) do
    html = render_component(&MediaComponents.transform_img/1, assigns)

    [attributes] =
      html |> LazyHTML.from_fragment() |> LazyHTML.query("img") |> LazyHTML.attributes()

    Map.new(attributes)
  end

  test "renders a signed, version-pinned srcset with Accept-negotiated formats" do
    attrs = img(item: item(), sizes: "50vw", widths: [400, 800])

    assert attrs["srcset"] ==
             ImageTransform.srcset(item(), [400, 800], format: :auto)

    assert attrs["srcset"] =~ ",fm_auto,v_#{ImageTransform.version(item())},s_"
    assert attrs["sizes"] == "50vw"
    # The fallback never asks for more than the widest candidate offered.
    assert attrs["src"] =~ "/t/w_800,fm_auto,"
    assert {attrs["width"], attrs["height"]} == {"2400", "1600"}
    assert attrs["alt"] == "A kiln at dusk"
    assert attrs["loading"] == "lazy"
    assert attrs["style"] == "object-position: 25% 50%"
  end

  test "a cropped set gets the crop's intrinsic size, and no object-position" do
    attrs = img(item: item(), aspect_ratio: "1:1", widths: [640])

    assert attrs["srcset"] =~ "w_640,ar_1:1,fm_auto"
    assert attrs["src"] =~ "/t/w_640,ar_1:1,"
    assert {attrs["width"], attrs["height"]} == {"1600", "1600"}
    refute Map.has_key?(attrs, "style")
  end

  test "caller attributes override the defaults" do
    attrs =
      img(item: item(), alt: "Override", loading: "eager", class: "hero", style: "opacity: 1")

    assert attrs["alt"] == "Override"
    assert attrs["loading"] == "eager"
    assert attrs["class"] == "hero"
    assert attrs["style"] == "opacity: 1"
  end

  test "with no widths given, the fallback is a 1080px rendering" do
    assert img(item: item())["src"] =~ "/t/w_1080,fm_auto,"
  end

  test "an item that can't be transformed falls back to its stored url, without a srcset" do
    attrs = img(item: item(%{width: nil, height: nil}))
    assert attrs["src"] == "/uploads/orig.jpg"
    refute Map.has_key?(attrs, "srcset")
    refute Map.has_key?(attrs, "sizes")
  end

  describe "thumb_src/2 (#3223)" do
    @thumb %{"thumb" => %{"url" => "/uploads/thumb.jpg"}}

    test "an image with a thumb variant previews as that variant, with or without fallback" do
      image = item(%{variants: @thumb})

      assert MediaComponents.thumb_src(image) == "/uploads/thumb.jpg"
      assert MediaComponents.thumb_src(image, fallback: false) == "/uploads/thumb.jpg"
    end

    test "an image without a thumb variant falls back to its original, unless told not to" do
      image = item(%{variants: %{}})

      assert MediaComponents.thumb_src(image) == "/uploads/orig.jpg"
      assert MediaComponents.thumb_src(image, fallback: false) == nil
    end

    test "an image no wider than the thumb variant is its own preview, even without fallback" do
      small = item(%{width: KilnCMS.ImageProcessor.thumb_width(), variants: %{}})
      wider = item(%{width: KilnCMS.ImageProcessor.thumb_width() + 1, variants: %{}})

      assert MediaComponents.thumb_src(small, fallback: false) == "/uploads/orig.jpg"
      assert MediaComponents.thumb_src(wider, fallback: false) == nil
    end

    test "a document has no preview" do
      document = item(%{content_type: "application/pdf", width: nil, height: nil, variants: %{}})

      assert MediaComponents.thumb_src(document) == nil
      assert MediaComponents.thumb_src(document, fallback: false) == nil
    end

    test "a gated image (no public url) has no preview" do
      assert MediaComponents.thumb_src(item(%{url: nil, variants: %{}})) == nil
    end

    test "a video previews as its poster frame, never the video itself" do
      poster = %{"poster" => %{"url" => "/uploads/poster.jpg"}}
      video = item(%{content_type: "video/mp4", url: "/uploads/clip.mp4"})

      assert MediaComponents.thumb_src(Map.put(video, :variants, poster)) == "/uploads/poster.jpg"
      assert MediaComponents.thumb_src(Map.put(video, :variants, %{})) == nil
    end
  end
end
