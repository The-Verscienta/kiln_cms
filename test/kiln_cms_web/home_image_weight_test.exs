defmodule KilnCMSWeb.HomeImageWeightTest do
  @moduledoc """
  #2165: the logo and the home-page screenshots stay right-sized.

  The budgets are asserted against the COMMITTED files, so a screenshot refresh
  that skips `scripts/optimize_home_images.sh` (and ships the raw 2880px
  captures) fails here rather than in a Lighthouse run. Budgets are the
  measured sizes plus modest headroom.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias KilnCMS.Branding
  alias KilnCMSWeb.Layouts

  @static Path.join(:code.priv_dir(:kiln_cms), "static")

  # Measured: logo-mark-sm.png 13.9 KB, .webp 6.2 KB.
  @logo_budget 15_000
  # Measured: largest fallback JPEG 166 KB; largest tour WebP 53 KB; hero 2880w 122 KB.
  @jpeg_budget 185_000
  @tour_webp_budget 60_000
  @hero_webp_budget 135_000
  # Measured page total on a 1.5x screen: hero 1440w 52 KB + three 720w
  # (13+19+11 KB) ~ 95 KB; the JPEG-only worst case is 4 fallbacks ~ 570 KB
  # (was ~937 KB of raw captures).
  @page_budget_webp 160_000
  @page_budget_jpeg 620_000

  defp size(path), do: File.stat!(Path.join(@static, path)).size

  defp brand(logo_url), do: %{Branding.defaults() | logo_url: logo_url}

  defp mark(brand) do
    assigns = %{brand: brand}

    rendered_to_string(~H"""
    <Layouts.brand_mark brand={@brand} class="h-7 w-auto" />
    """)
  end

  # Walks the JPEG's marker segments to its SOFn frame header (a bare search for
  # `FF C0` can land inside EXIF/ICC data). SOF0..SOF15 except DHT (C4), JPG
  # (C8) and DAC (CC) carry the frame size.
  defp jpeg_width(path) do
    <<0xFF, 0xD8, rest::binary>> = File.read!(Path.join(@static, path))
    jpeg_segments(rest)
  end

  defp jpeg_segments(<<0xFF, marker, _len::16, body::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC] do
    <<_precision::8, _height::16, width::16, _::binary>> = body
    width
  end

  defp jpeg_segments(<<0xFF, _marker, len::16, rest::binary>>) do
    skip = len - 2
    <<_::binary-size(^skip), tail::binary>> = rest
    jpeg_segments(tail)
  end

  describe "logo" do
    test "the stock mark renders as a sized WebP/PNG picture" do
      html = mark(Branding.defaults())

      assert html =~
               ~r{<picture[^>]*>\s*<source type="image/webp" srcset="/images/logo-mark-sm[^"]*\.webp"}

      assert html =~ ~r{<img src="/images/logo-mark-sm[^"]*\.png"[^>]*width="88"[^>]*height="120"}
      refute html =~ "logo-mark.png"
    end

    test "an operator's own logo is a plain <img> of exactly that URL" do
      html = mark(brand("/uploads/acme.png"))

      assert html =~ ~s(src="/uploads/acme.png")
      refute html =~ "<picture"
      refute html =~ "logo-mark-sm"
    end

    test "the unbranded fail-closed path still gets the stock picture" do
      brand = Layouts.brand_or_unbranded(%{})

      assert mark(brand) =~ "<picture"
    end

    test "the variants are small and the original is untouched" do
      assert size("images/logo-mark-sm.png") <= @logo_budget
      assert size("images/logo-mark-sm.webp") <= @logo_budget
      assert Branding.default_logo_url() == "/images/logo-mark.png"
      assert File.exists?(Path.join(@static, "images/logo-mark.png"))
    end
  end

  describe "home page screenshots" do
    setup %{conn: conn}, do: %{html: conn |> get(~p"/") |> html_response(200)}

    test "the hero is a high-priority, eager picture with a WebP srcset", %{html: html} do
      [hero] =
        Regex.run(
          ~r{<picture[^>]*>(?:(?!</picture>).)*editor(?:(?!</picture>).)*</picture>}s,
          html
        )

      assert hero =~
               ~r{<source type="image/webp"[^>]*srcset="[^"]*editor-720\.webp 720w, [^"]*editor-1440\.webp 1440w, [^"]*editor-2880\.webp 2880w"}s

      assert hero =~ ~r{sizes="[^"]*940px}
      assert hero =~ ~s(fetchpriority="high")
      assert hero =~ ~s(width="1440")
      assert hero =~ ~s(height="900")
      refute hero =~ ~s(loading="lazy")
    end

    test "the tour shots are lazy pictures with 720w and 1440w WebP", %{html: html} do
      for name <- ~w(content calendar media) do
        [pic] =
          Regex.run(
            ~r{<picture[^>]*>(?:(?!</picture>).)*/#{name}[-.](?:(?!</picture>).)*</picture>}s,
            html
          )

        assert pic =~ ~r{srcset="[^"]*#{name}-720\.webp 720w, [^"]*#{name}-1440\.webp 1440w"}
        assert pic =~ ~s(loading="lazy")
        assert pic =~ ~s(width="1440")
        refute pic =~ "fetchpriority"
      end
    end

    test "every committed variant is within its byte budget" do
      for n <- ~w(editor content calendar media) do
        assert size("images/home/#{n}.jpg") <= @jpeg_budget, "#{n}.jpg"
        assert jpeg_width("images/home/#{n}.jpg") <= 1440, "#{n}.jpg is a raw capture"
        assert size("images/home/#{n}-720.webp") <= @tour_webp_budget
        assert size("images/home/#{n}-1440.webp") <= @tour_webp_budget
      end

      assert size("images/home/editor-2880.webp") <= @hero_webp_budget
    end

    test "the page's image weight stays under budget", %{html: html} do
      # What a visitor can be made to fetch: per picture, the largest of the
      # candidates a 1.5x screen picks (hero 1440w, tour shots 720w), or the JPEG
      # fallback.
      pics = Regex.scan(~r{<picture[^>]*>.*?</picture>}s, html) |> Enum.map(&hd/1)
      home = Enum.filter(pics, &(&1 =~ "/images/home/"))
      assert length(home) == 4

      jpeg_total =
        for pic <- home, [_, path] = Regex.run(~r{<img src="([^"]+)"}, pic), reduce: 0 do
          acc -> acc + size(String.trim_leading(path, "/"))
        end

      webp_total =
        for pic <- home, reduce: 0 do
          acc ->
            [_, srcset] = Regex.run(~r{srcset="([^"]+)"}, pic)

            # What the page's `sizes` make a 1.5x screen fetch: the hero (eager,
            # fetchpriority=high) at 1440w, each lazy tour shot at 720w.
            wanted = if pic =~ "fetchpriority", do: "1440w", else: "720w"

            candidate =
              srcset
              |> String.split(",")
              |> Enum.map(&String.split(String.trim(&1)))
              |> Enum.find(fn [_path, width] -> width == wanted end)

            assert candidate, "no #{wanted} candidate in #{srcset}"
            [path, _] = candidate
            acc + size(String.trim_leading(path, "/"))
        end

      assert jpeg_total <= @page_budget_jpeg
      assert webp_total <= @page_budget_webp
    end
  end
end
