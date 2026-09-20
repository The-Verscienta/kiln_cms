defmodule KilnClient.ImageTest do
  # Not async: these read `:public_url`/`:base_url` and set
  # `:image_transform_key`, and KilnClientTest mutates the same app env.
  use ExUnit.Case, async: false

  alias KilnClient.Image

  # Generated from the server's implementation and shared with the JS SDK —
  # every builder must reproduce it byte-for-byte. Never edit it here; see its
  # `_comment` for how it is regenerated.
  @fixture_path Path.expand("../../../../js/test/fixtures/image_transform_vectors.json", __DIR__)
  @external_resource @fixture_path
  @vectors @fixture_path |> File.read!() |> Jason.decode!()

  @base "http://kiln.test"

  @photo @vectors["media"]["photo"]

  setup do
    on_exit(fn ->
      Application.delete_env(:kiln_client, :image_transform_key)
      Application.delete_env(:kiln_client, :public_url)
    end)
  end

  # Fixture options are snake_case strings; map them onto keyword options.
  defp opts(options, key) do
    Enum.map(options, fn
      {name, v} when name in ~w(fit crop format) -> {String.to_atom(name), String.to_atom(v)}
      {name, v} -> {String.to_atom(name), v}
    end) ++ [sign_key: key]
  end

  defp media(name), do: Map.fetch!(@vectors["media"], name)

  # The fixture pins root-relative paths; `srcset/2` builds absolute URLs.
  defp absolute_srcset(nil), do: nil
  defp absolute_srcset(srcset), do: String.replace(srcset, "/media/", @base <> "/media/")

  describe "shared vectors" do
    test "the client's default ladder is the server's" do
      # Every rung survives unsigned snapping unchanged, and one past each
      # rung snaps to the next — so the two ladders are the same list.
      ladder = @vectors["sizes"]

      for {size, next} <- Enum.zip(ladder, tl(ladder)) do
        assert Image.path(@photo, width: size) =~ "/t/w_#{size},"
        assert Image.path(@photo, width: size + 1) =~ "/t/w_#{next},"
      end
    end

    for %{"media" => name} = vector <- @vectors["versions"] do
      @tag vector: vector
      test "version/1: #{name}", %{vector: vector} do
        assert Image.version(media(vector["media"])) == vector["expected"]
      end
    end

    # Each vector rides in via a tag rather than `unquote`, so the compiler
    # doesn't type-check a literal map per test.
    for %{"name" => name} = vector <- @vectors["urls"] do
      @tag vector: vector
      test "path/2 and url/2: #{name}", %{vector: vector} do
        %{"media" => m, "options" => options, "key" => key, "expected" => expected} = vector

        assert Image.path(media(m), opts(options, key)) == expected
        assert Image.url(media(m), opts(options, key)) == @base <> expected
      end
    end

    for %{"name" => name} = vector <- @vectors["srcsets"] do
      @tag vector: vector
      test "srcset/2: #{name}", %{vector: vector} do
        %{"media" => m, "options" => options, "key" => key, "widths" => widths} = vector

        opts = opts(options, key) ++ [widths: widths]
        assert Image.srcset(media(m), opts) == absolute_srcset(vector["expected"])
      end
    end

    test "atom-keyed media builds the same URLs" do
      atom_photo = Map.new(@photo, fn {k, v} -> {String.to_existing_atom(k), v} end)

      for %{"media" => "photo", "options" => options, "key" => key, "expected" => expected} <-
            @vectors["urls"] do
        assert Image.path(atom_photo, opts(options, key)) == expected
      end
    end
  end

  describe "signing key" do
    test "the configured :image_transform_key signs by default" do
      key = @vectors["signing_key"]
      Application.put_env(:kiln_client, :image_transform_key, key)

      assert Image.path(@photo, width: 801, height: 451) ==
               Image.path(@photo, width: 801, height: 451, sign_key: key)

      assert Image.path(@photo, width: 801) =~ ~r/,s_[A-Za-z0-9_-]{22}\z/
    end

    test "sign_key: nil forces an unsigned (snapped) URL over the configured key" do
      Application.put_env(:kiln_client, :image_transform_key, "configured")

      assert Image.path(@photo, width: 801, sign_key: nil) ==
               "/media/#{@photo["id"]}/t/w_828,v_4b87b277"
    end

    test "an empty key is no key" do
      Application.put_env(:kiln_client, :image_transform_key, "")
      refute Image.path(@photo, width: 801) =~ ",s_"
    end
  end

  describe "options" do
    test "tuple aspect ratios and string enum values match their canonical forms" do
      assert Image.path(@photo, aspect_ratio: {16, 9}, fit: "contain", format: "webp") ==
               Image.path(@photo, aspect_ratio: "16:9", fit: :contain, format: :webp)
    end

    test ":sizes overrides the unsigned ladder" do
      assert Image.path(@photo, width: 500, height: 2000, sizes: [1000, 400, 800]) ==
               "/media/#{@photo["id"]}/t/w_800,h_1000,v_4b87b277"
    end

    test "srcset/2 ignores :height and returns nil without dimensions" do
      assert Image.srcset(@photo, widths: [640], height: 300) ==
               "#{@base}/media/#{@photo["id"]}/t/w_640,v_4b87b277 640w"

      assert Image.srcset(Map.put(@photo, "width", nil), widths: [640]) == nil
      assert Image.srcset(Map.put(@photo, "height", 0), widths: [640]) == nil
    end

    test "srcset/2 rounds the aspect-ratio window to the nearest pixel" do
      # 1000 * 16 / 9 = 1777.8: described as 1778w (not truncated to 1777).
      wide = %{"id" => "m1", "width" => 5000, "height" => 1000}

      assert Image.srcset(wide, widths: [1920], aspect_ratio: "16:9", sign_key: "k") =~
               ~r/ 1778w\z/
    end

    test "url/2 prefixes public_url, without doubling a trailing slash" do
      Application.put_env(:kiln_client, :public_url, "https://img.example.com/")

      assert Image.url(@photo, width: 640) ==
               "https://img.example.com/media/#{@photo["id"]}/t/w_640,v_4b87b277"

      assert KilnClient.image_url(@photo, width: 640) == Image.url(@photo, width: 640)

      assert KilnClient.image_srcset(@photo, widths: [640]) ==
               "https://img.example.com/media/#{@photo["id"]}/t/w_640,v_4b87b277 640w"
    end
  end

  describe "validation" do
    for {opt, bad} <- [
          width: 0,
          width: -5,
          width: 1.5,
          width: "800",
          height: 0,
          dpr: 4,
          dpr: 0,
          quality: 0,
          quality: 101,
          fit: :stretch,
          crop: :middle,
          format: :gif,
          format: "GIF",
          aspect_ratio: "0:9",
          aspect_ratio: "100:1",
          aspect_ratio: "16/9",
          aspect_ratio: "16:09",
          aspect_ratio: {0, 1},
          aspect_ratio: {1.5, 1},
          aspect_ratio: 1.78,
          sizes: []
        ] do
      test "#{opt}: #{inspect(bad)} raises" do
        assert_raise ArgumentError, fn ->
          Image.path(@photo, [{unquote(opt), unquote(Macro.escape(bad))}, width: 640])
        end
      end
    end

    test ":height with :aspect_ratio raises, signed or not" do
      for key <- [nil, "k"] do
        assert_raise ArgumentError, ~r/not both/, fn ->
          Image.path(@photo, width: 640, height: 360, aspect_ratio: "16:9", sign_key: key)
        end
      end

      # srcset/2 drops :height instead, so the pair is fine there.
      assert Image.srcset(@photo, widths: [640], height: 360, aspect_ratio: "16:9")
    end

    test "signed URLs validate too" do
      assert_raise ArgumentError, fn -> Image.path(@photo, width: 0, sign_key: "k") end
    end

    test "srcset widths must be positive integers" do
      assert_raise ArgumentError, fn -> Image.srcset(@photo, widths: [640, 0]) end
    end

    test "media without an id raises" do
      assert_raise ArgumentError, fn -> Image.path(%{"url" => "/x.jpg"}, width: 640) end
    end
  end
end
