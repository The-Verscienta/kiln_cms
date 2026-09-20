defmodule KilnCMS.Media.ImageTransformTest do
  @moduledoc """
  The transform URL grammar, its authorization (signature or allowlist), the
  version pin and the geometry planner — all pure, no storage or libvips.
  """
  # async: false — several tests put `:image_transforms` config in the app env.
  use ExUnit.Case, async: false

  alias KilnCMS.Media.ImageTransform
  alias KilnCMS.Media.ImageTransform.Params

  @id "8a5b8e4e-7b8f-4a57-9a5e-2f3a1c9d0b11"

  setup do
    previous = Application.get_env(:kiln_cms, :image_transforms)
    Application.put_env(:kiln_cms, :image_transforms, signing_key: "unit-test-key")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, :image_transforms, previous),
        else: Application.delete_env(:kiln_cms, :image_transforms)
    end)
  end

  defp config(opts) do
    Application.put_env(
      :kiln_cms,
      :image_transforms,
      Keyword.merge([signing_key: "unit-test-key"], opts)
    )
  end

  defp image(attrs \\ %{}) do
    Map.merge(
      %{
        id: @id,
        url: "/uploads/orig.jpg",
        storage_key: "orig.jpg",
        content_type: "image/jpeg",
        width: 2400,
        height: 1600,
        focal_x: 0.5,
        focal_y: 0.5,
        audience: :public
      },
      attrs
    )
  end

  defp plan!(ops, item \\ image(), accept \\ nil) do
    {:ok, params} = ImageTransform.parse(ops)
    {:ok, plan} = ImageTransform.plan(item, params, accept)
    plan
  end

  describe "parse/1" do
    test "reads every parameter" do
      assert {:ok, params} =
               ImageTransform.parse(
                 "w_800,ar_16:9,dpr_2,fit_contain,crop_top,fm_webp,q_70,v_0a1b2c3d"
               )

      assert %Params{
               w: 800,
               ar: {16, 9},
               dpr: 2,
               fit: :contain,
               crop: :top,
               fm: :webp,
               q: 70,
               v: "0a1b2c3d"
             } = params
    end

    test "accepts any order and canonicalizes to one" do
      {:ok, a} = ImageTransform.parse("q_70,fm_webp,w_800,h_600")
      {:ok, b} = ImageTransform.parse("w_800,h_600,fm_webp,q_70")
      assert ImageTransform.canonical(a) == "w_800,h_600,fm_webp,q_70"
      assert ImageTransform.canonical(a) == ImageTransform.canonical(b)
    end

    test "the canonical form never includes the signature" do
      {:ok, params} = ImageTransform.parse("w_800,s_AAAAAAAAAAAAAAAAAAAAAA")
      assert ImageTransform.canonical(params) == "w_800"
    end

    for {ops, why} <- [
          {"", "empty"},
          {"w_800,", "trailing comma"},
          {"w800", "no separator"},
          {"x_1", "unknown key"},
          {"w_800,w_900", "repeated key"},
          {"w_0", "zero"},
          {"w_0800", "leading zero"},
          {"w_-5", "negative"},
          {"w_4001", "over the maximum"},
          {"w_1.5", "fraction"},
          {"h_400,ar_16:9", "h and ar together"},
          {"ar_16x9", "wrong ratio separator"},
          {"ar_0:9", "zero ratio term"},
          {"ar_100:1", "ratio term over 99"},
          {"dpr_4", "dpr out of range"},
          {"fit_fill", "unknown fit"},
          {"crop_face", "unknown crop"},
          {"fm_gif", "unsupported output format"},
          {"q_101", "quality over 100"},
          {"v_XYZ", "malformed version"},
          {"s_short", "malformed signature"}
        ] do
      test "rejects #{why}" do
        assert {:error, :bad_request, message} = ImageTransform.parse(unquote(ops))
        assert is_binary(message)
      end
    end

    test "rejects an oversized segment before splitting it" do
      assert {:error, :bad_request, _} =
               ImageTransform.parse(String.duplicate("w_16,", 60) <> "w_16")
    end

    test "names a repeated key instead of calling it malformed" do
      assert {:error, :bad_request, "Parameter w given twice."} =
               ImageTransform.parse("w_800,w_900")
    end

    test "the maximum dimension is configurable" do
      config(max_dimension: 1000)
      assert {:error, :bad_request, _} = ImageTransform.parse("w_1001")
      assert {:ok, %Params{w: 1000}} = ImageTransform.parse("w_1000")
    end
  end

  describe "authorize/2" do
    test "an unsigned request on the allowlist passes" do
      {:ok, params} = ImageTransform.parse("w_828,ar_16:9,q_75,fm_auto")
      assert :ok = ImageTransform.authorize(@id, params)
    end

    test "an unsigned off-list width, height, ratio or quality is a 400 naming the allowlist" do
      for ops <- ["w_800", "h_801", "w_640,ar_7:5", "w_640,q_80"] do
        {:ok, params} = ImageTransform.parse(ops)
        assert {:error, :bad_request, message} = ImageTransform.authorize(@id, params)
        assert message =~ "needs a signed URL"
      end
    end

    test "a signed request may use any in-range value" do
      {:ok, params} = ImageTransform.parse("w_801,h_333,q_63")
      signature = ImageTransform.sign(@id, ImageTransform.canonical(params))
      {:ok, signed} = ImageTransform.parse("w_801,h_333,q_63,s_#{signature}")
      assert :ok = ImageTransform.authorize(@id, signed)
    end

    test "the signature binds the item and every parameter" do
      signature = ImageTransform.sign(@id, "w_801")

      {:ok, other_width} = ImageTransform.parse("w_802,s_#{signature}")

      assert {:error, :forbidden, "Invalid signature."} =
               ImageTransform.authorize(@id, other_width)

      {:ok, same} = ImageTransform.parse("w_801,s_#{signature}")
      assert :ok = ImageTransform.authorize(@id, same)
      assert {:error, :forbidden, _} = ImageTransform.authorize(Ecto.UUID.generate(), same)
    end

    test "a signature under a different key is refused" do
      {:ok, params} = ImageTransform.parse("w_801")
      forged = ImageTransform.sign(@id, "w_801", "some-other-key")
      assert {:error, :forbidden, _} = ImageTransform.authorize(@id, %{params | s: forged})
    end

    test "unsigned requests can be turned off entirely" do
      config(allow_unsigned: false)
      {:ok, params} = ImageTransform.parse("w_640")
      assert {:error, :forbidden, _} = ImageTransform.authorize(@id, params)
    end

    test "the allowlists are configurable" do
      config(sizes: [100, 200], aspect_ratios: ["7:5"], unsigned_qualities: [80])

      for ops <- ["w_100", "h_200", "w_100,ar_7:5", "q_80"] do
        {:ok, params} = ImageTransform.parse(ops)
        assert :ok = ImageTransform.authorize(@id, params)
      end

      {:ok, params} = ImageTransform.parse("w_640")
      assert {:error, :bad_request, _} = ImageTransform.authorize(@id, params)
    end
  end

  describe "signing_key/0" do
    test "uses the configured key verbatim" do
      assert ImageTransform.signing_key() == "unit-test-key"
    end

    test "without one, derives a stable 32-byte key from secret_key_base" do
      Application.put_env(:kiln_cms, :image_transforms, [])
      key = ImageTransform.signing_key()
      assert byte_size(key) == 32
      assert key == ImageTransform.signing_key()
      refute key == KilnCMSWeb.Endpoint.config(:secret_key_base)
    end
  end

  describe "version/1" do
    test "is 8 hex digits and moves with the url and the focal point" do
      base = ImageTransform.version(image())
      assert base =~ ~r/\A[0-9a-f]{8}\z/
      refute ImageTransform.version(image(%{url: "/uploads/rotated.jpg"})) == base
      refute ImageTransform.version(image(%{focal_x: 0.3})) == base
      assert ImageTransform.version(image(%{storage_key: "unrelated"})) == base
    end

    test "a missing focal point reads as the centre" do
      assert ImageTransform.version(image(%{focal_x: nil, focal_y: nil})) ==
               ImageTransform.version(image())
    end

    test "works on a JSON map with string keys" do
      json = %{"url" => "/uploads/orig.jpg", "focal_x" => 0.5, "focal_y" => 0.5}
      assert ImageTransform.version(json) == ImageTransform.version(image())
    end
  end

  describe "geometry" do
    test "a width alone scales proportionally and never upscales" do
      assert %{crop: nil, width: 800, height: 533} = plan!("w_800")
      assert %{crop: nil, width: 2400, height: 1600} = plan!("w_3840")
    end

    test "a height alone scales proportionally" do
      assert %{crop: nil, width: 600, height: 400} = plan!("h_400")
    end

    test "dpr multiplies the requested size" do
      assert %{width: 1600, height: 1067} = plan!("w_800,dpr_2")
    end

    test "cover crops the largest window of the box's ratio, around the focal point" do
      item = image(%{focal_x: 0.1, focal_y: 0.5})
      plan = plan!("w_640,h_640", item)

      # 1600x1600 window; centred on x=240 it would start left of 0, so it
      # clamps to the left edge.
      assert plan.crop == {0, 0, 1600, 1600}
      assert {plan.width, plan.height} == {640, 640}
    end

    test "the crop anchor can be pinned instead of following the focal point" do
      item = image(%{focal_x: 0.1, focal_y: 0.1})
      assert %{crop: {400, 0, 1600, 1600}} = plan!("w_640,h_640,crop_center", item)
      assert %{crop: {800, 0, 1600, 1600}} = plan!("w_640,h_640,crop_right", item)
      assert %{crop: {0, 0, 1600, 1600}} = plan!("w_640,h_640,crop_left", item)

      tall = image(%{width: 1000, height: 3000})
      assert %{crop: {0, 0, 1000, 1000}} = plan!("w_256,h_256,crop_top", tall)
      assert %{crop: {0, 2000, 1000, 1000}} = plan!("w_256,h_256,crop_bottom", tall)
    end

    test "an aspect ratio with a width is a cover box" do
      assert %{crop: {0, 125, 2400, 1350}, width: 1080, height: 608} = plan!("w_1080,ar_16:9")
    end

    test "an aspect ratio alone crops to the ratio at full resolution" do
      assert %{crop: {400, 0, 1600, 1600}, width: 1600, height: 1600} = plan!("ar_1:1")
    end

    test "a cover box larger than the window keeps the window's size, not the box's" do
      assert %{crop: {400, 0, 1600, 1600}, width: 1600, height: 1600} =
               plan!("w_3840,h_3840")
    end

    test "contain fits inside the box without cropping" do
      assert %{crop: nil, width: 600, height: 400} = plan!("w_640,h_400,fit_contain")
    end

    test "a crop that covers the whole frame is no crop" do
      assert %{crop: nil, width: 750, height: 500} = plan!("w_750,ar_3:2")
    end

    test "the output cap shrinks a box as a whole, keeping its ratio" do
      config(max_dimension: 1000)
      item = image(%{width: 4000, height: 4000})
      assert %{width: 500, height: 1000} = plan!("w_1000,ar_1:2", item)
      assert %{width: 1000, height: 1000} = plan!("w_1000,dpr_3", item)
    end
  end

  describe "plan/3" do
    test "refuses what is not a transformable raster image" do
      {:ok, params} = ImageTransform.parse("w_640")

      for item <- [
            image(%{content_type: "application/pdf"}),
            image(%{content_type: "image/svg+xml"}),
            image(%{content_type: "video/mp4"}),
            image(%{width: nil, height: nil}),
            image(%{storage_key: nil})
          ] do
        assert {:error, :unprocessable, _} = ImageTransform.plan(item, params)
      end
    end

    test "refuses a source over the pixel cap before anything is decoded" do
      config(max_source_pixels: 1_000_000)
      {:ok, params} = ImageTransform.parse("w_640")

      assert {:error, :unprocessable, "This image is too large to transform."} =
               ImageTransform.plan(image(), params)
    end

    test "defaults to the source's format, and a GIF to PNG" do
      assert %{format: :jpg, content_type: "image/jpeg", ext: ".jpg"} = plan!("w_640")

      assert %{format: :png} =
               plan!("w_640", image(%{content_type: "image/gif"}))
    end

    test "fm_auto negotiates from Accept and says so with Vary" do
      assert %{format: :webp, vary_accept?: true} =
               plan!("w_640,fm_auto", image(), "image/avif,image/webp,*/*")

      assert %{format: :jpg, vary_accept?: true} = plan!("w_640,fm_auto", image(), "*/*")

      # A WebP source for a client that can't take WebP: lossless, keeps alpha.
      assert %{format: :png} =
               plan!("w_640,fm_auto", image(%{content_type: "image/webp"}), "image/png")

      refute plan!("w_640,fm_webp").vary_accept?
    end

    test "fm_auto offers AVIF only when the operator opts in" do
      refute plan!("w_640,fm_auto", image(), "image/avif,image/webp").format == :avif
      config(auto_avif: true)
      assert %{format: :avif} = plan!("w_640,fm_auto", image(), "image/avif,image/webp")
    end

    test "quality defaults per format, and PNG carries none" do
      assert %{quality: 82} = plan!("w_640,fm_webp")
      assert %{quality: 40} = plan!("w_640,fm_webp,q_40")
      assert %{quality: nil} = plan!("w_640,fm_png,q_40")
    end

    test "the cache key is what is rendered, not how it was asked for" do
      assert plan!("w_1600").cache_key == plan!("w_800,dpr_2").cache_key
      assert plan!("w_3840").cache_key == plan!("w_2400").cache_key
      assert plan!("fm_png,q_90").cache_key == plan!("fm_png").cache_key
      refute plan!("w_800").cache_key == plan!("w_800,fm_webp").cache_key

      refute plan!("w_800").cache_key ==
               plan!("w_800", image(%{storage_key: "rotated.jpg"})).cache_key

      assert plan!("w_800").cache_key =~ ~r/\At-[0-9a-f]{32}\z/
    end

    test "a moved focal point changes a focal crop's key, not a plain resize's" do
      moved = image(%{focal_x: 0.1})
      assert plan!("w_800").cache_key == plan!("w_800", moved).cache_key
      refute plan!("w_640,h_640").cache_key == plan!("w_640,h_640", moved).cache_key
    end

    test "records the focal point only for crops anchored on it" do
      assert %{focal: "500:500"} = plan!("w_640,h_640")
      assert %{focal: nil} = plan!("w_640,h_640,crop_center")
      assert %{focal: nil} = plan!("w_640")
    end
  end

  describe "url/2 and srcset/3" do
    test "a server-built URL is signed, versioned and authorizes" do
      item = image()
      path = ImageTransform.url(item, width: 801, aspect_ratio: "16:9", format: :webp)
      assert "/media/" <> rest = path
      [id, "t", ops] = String.split(rest, "/")
      assert id == @id
      {:ok, params} = ImageTransform.parse(ops)
      assert params.v == ImageTransform.version(item)
      assert :ok = ImageTransform.authorize(id, params)
    end

    test "an unsigned URL snaps to the allowlist and authorizes" do
      path = ImageTransform.url(image(), width: 801, sign: false)
      assert path =~ "/t/w_828,v_"
      [_, ops] = String.split(path, "/t/")
      {:ok, params} = ImageTransform.parse(ops)
      assert :ok = ImageTransform.authorize(@id, params)
    end

    test "srcset describes each candidate by what it renders, and stops at the source" do
      srcset = ImageTransform.srcset(image(%{width: 1000, height: 800}), [256, 640, 1080, 1920])

      descriptors =
        srcset |> String.split(", ") |> Enum.map(&(&1 |> String.split(" ") |> List.last()))

      assert descriptors == ["256w", "640w", "1000w"]
    end

    test "height and aspect ratio together are refused, as the grammar refuses them" do
      assert_raise ArgumentError, fn ->
        ImageTransform.url(image(), height: 400, aspect_ratio: "16:9")
      end
    end

    test "srcset is nil for an item with no dimensions" do
      assert ImageTransform.srcset(image(%{width: nil}), [256]) == nil
    end
  end
end
