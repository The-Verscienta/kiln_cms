defmodule KilnCMS.Branding.AppIconTest do
  @moduledoc """
  The app-icon probe (#629).

  The reason this module exists at all is that `icons[].sizes` in a web app
  manifest is a *claim*, and Chromium's installability check believes it. So the
  interesting assertions here are the refusals: every one of them is a case
  where declaring the icon anyway would remove the install prompt outright,
  silently, with nothing in the UI to say why.

  `async: false` because the setup below widens the image-host policy
  (`:csp_img_src`) for the whole VM — an absolute URL cannot be verified at all
  unless its host is one the CSP would let a browser load, which is
  `BrandTokens`' rule and deliberately not relaxed for this module.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Branding.AppIcon

  @stub KilnCMS.Branding.AppIcon

  # An operator's icon CDN, as they would have had to configure it: `AppIcon`
  # refuses to dial a host the site's own image policy would not load.
  @cdn "https://cdn.test/icon.png"

  setup do
    previous = Application.get_env(:kiln_cms, :csp_img_src, [])
    Application.put_env(:kiln_cms, :csp_img_src, ["cdn.test"])
    on_exit(fn -> Application.put_env(:kiln_cms, :csp_img_src, previous) end)
    :ok
  end

  # A real image, because the probe reads real image headers and now also checks
  # the real decoded format — a fixture of made-up bytes would pass a mock and
  # tell us nothing about libvips.
  defp image(width, height, suffix \\ ".png") do
    {:ok, image} = Image.new(width, height, color: :green)
    path = Path.join(System.tmp_dir!(), "icon-#{System.unique_integer([:positive])}#{suffix}")
    {:ok, _image} = Image.write(image, path)
    bytes = File.read!(path)
    File.rm(path)
    bytes
  end

  defp serve(bytes) do
    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, bytes)
    end)
  end

  describe "verify/1 accepts an installable icon" do
    test "a square PNG at the minimum edge reports its size" do
      serve(image(512, 512))

      assert {:ok, 512} = AppIcon.verify(@cdn)
    end

    test "larger than the minimum is fine, and the real edge is what comes back" do
      # The manifest declares whatever this returns, so rounding it down to 512
      # would be a lie in the other direction.
      serve(image(1024, 1024))

      assert {:ok, 1024} = AppIcon.verify(@cdn)
    end

    test "a JPEG is accepted too — iOS renders those" do
      serve(image(512, 512, ".jpg"))

      assert {:ok, 512} = AppIcon.verify(@cdn)
    end

    test "surrounding whitespace is trimmed rather than making the URL unfetchable" do
      serve(image(512, 512))

      assert {:ok, 512} = AppIcon.verify("  #{@cdn}\n")
    end

    test "a redirect is followed — a CDN alias is a working URL, not a dead one" do
      Req.Test.stub(@stub, fn conn ->
        case conn.request_path do
          "/icon.png" ->
            conn
            |> Plug.Conn.put_resp_header("location", "https://cdn.test/real-icon.png")
            |> Plug.Conn.send_resp(301, "")

          "/real-icon.png" ->
            conn
            |> Plug.Conn.put_resp_content_type("image/png")
            |> Plug.Conn.send_resp(200, image(512, 512))
        end
      end)

      assert {:ok, 512} = AppIcon.verify(@cdn)
    end
  end

  describe "verify/1 refuses what would break the install prompt" do
    test "a non-square image names both dimensions" do
      # The wordmark case: an operator pastes their logo, which is 1200×300.
      serve(image(1200, 300))

      assert {:error, {:not_square, 1200, 300}} = AppIcon.verify(@cdn)
    end

    test "a square image below the minimum edge reports the edge it has" do
      serve(image(256, 256))

      assert {:error, {:too_small, 256}} = AppIcon.verify(@cdn)
    end

    test "one pixel under the minimum is still under" do
      serve(image(511, 511))

      assert {:error, {:too_small, 511}} = AppIcon.verify(@cdn)
    end

    test "a WebP is refused even though the media library accepts one" do
      # Narrower than the uploader on purpose: `apple-touch-icon` is the one PWA
      # surface with no format negotiation and no second candidate, and iOS
      # answers a WebP there by ignoring it and using a screenshot of the page.
      serve(image(512, 512, ".webp"))

      assert {:error, :not_an_image} = AppIcon.verify(@cdn)
    end

    test "the format is read from the bytes, not from the extension" do
      # An image CDN serving WebP from a `.png` path is routine. The URL says
      # PNG; the loader says otherwise, and the loader wins.
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, image(512, 512, ".webp"))
      end)

      assert {:error, :not_an_image} = AppIcon.verify(@cdn)
    end

    test "bytes that are not an image at all" do
      Req.Test.stub(@stub, fn conn ->
        Plug.Conn.send_resp(conn, 200, "<!doctype html><title>404</title>")
      end)

      assert {:error, :not_an_image} = AppIcon.verify(@cdn)
    end

    test "a body past the size cap says so, rather than blaming the network" do
      # This pins a coupling: `SafeFetch` reports its streaming cap as prose, and
      # `too_large?/1` matches on it. Reword that message and this goes red —
      # which is the point, because the alternative is silently folding the case
      # back into `:unreachable` and telling an operator to check their DNS
      # about a file their CDN serves perfectly.
      Req.Test.stub(@stub, fn conn ->
        Plug.Conn.send_resp(conn, 200, :binary.copy("x", 5 * 1024 * 1024))
      end)

      assert {:error, :too_large} = AppIcon.verify(@cdn)
    end

    test "a non-2xx answer is unreachable, not a broken image" do
      # The distinction matters to the operator: 'your CDN 404s' and 'your file
      # is the wrong shape' send them to completely different places.
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, :unreachable} = AppIcon.verify(@cdn)
    end

    test "a 200 with an empty body is unreachable" do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

      assert {:error, :unreachable} = AppIcon.verify(@cdn)
    end

    test "a transport failure is unreachable rather than an exception" do
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, :unreachable} = AppIcon.verify(@cdn)
    end
  end

  describe "verify/1 with nothing to verify" do
    test "nil, empty and whitespace are all 'not configured'" do
      for value <- [nil, "", "   ", "\n\t"] do
        assert {:error, :not_configured} = AppIcon.verify(value),
               "expected #{inspect(value)} to read as unset"
      end
    end
  end

  describe "the URL policy is enforced by this module, not by its caller" do
    test "a host outside the site's image policy is refused before any fetch" do
      # The gate lives here rather than in `BrandingLive` because this function
      # is what dials the URL. A second caller — a re-verification job, an
      # import — must not be able to reach the fetch by forgetting a guard.
      #
      # No stub is installed: if the policy check did not run first, the request
      # would reach the configured Req.Test stub and fail as "no stub", not as
      # `:not_allowed`.
      for url <- [
            "https://evil.example.com/icon.png",
            "http://cdn.test/icon.png",
            "//cdn.test/icon.png",
            "javascript:alert(1)",
            "data:image/png;base64,AAAA",
            "file:///etc/passwd"
          ] do
        assert {:error, :not_allowed} = AppIcon.verify(url), "expected #{url} to be refused"
      end
    end

    test "a same-origin path outside the media library says so specifically" do
      # `/images/brand.png` is a real file this app serves, but it is not a
      # storage key. The previous version passed it through to `Storage`, which
      # rejected it, and the operator was told a URL their browser loads fine
      # was not "publicly reachable" — advice that could never work.
      assert {:error, :not_in_media_library} = AppIcon.verify("/images/logo-mark.png")
    end
  end

  describe "the fetch is SSRF-hardened" do
    @tag :capture_log
    test "a policy-allowed host that resolves to a private address is still refused" do
      # `localhost` is the endpoint's own host, so it passes the image policy —
      # this is the case where the allowlist does NOT save us and the address
      # pinning in `SafeFetch` is the only thing left. It is also the shape an
      # attacker would actually reach for: not an obviously-internal URL, but a
      # permitted name that resolves inward.
      assert {:error, :unreachable} = AppIcon.verify("https://localhost/icon.png")
    end
  end

  describe "reading from the media library" do
    setup do
      key = "app-icon-#{System.unique_integer([:positive])}.png"
      path = Path.join(System.tmp_dir!(), key)
      File.write!(path, image(512, 512))
      {:ok, _stored} = KilnCMS.Storage.store(key, path)
      File.rm(path)
      on_exit(fn -> KilnCMS.Storage.delete(key) end)

      %{key: key}
    end

    test "an uploaded path is read through Storage, not dialled over HTTP", %{key: key} do
      # No Req.Test stub is installed for this one on purpose: a same-origin
      # `/uploads/…` must never become an HTTP request, or a site behind basic
      # auth or on a private network could not verify its own icon.
      assert {:ok, 512} = AppIcon.verify("/uploads/#{key}")
    end

    test "a query string or fragment on the path does not break the key", %{key: key} do
      assert {:ok, 512} = AppIcon.verify("/uploads/#{key}?v=2")
    end

    test "a missing upload is unreachable" do
      assert {:error, :unreachable} =
               AppIcon.verify("/uploads/nope-#{:erlang.unique_integer()}.png")
    end
  end

  describe "explain/1" do
    test "names the specific problem, with the numbers" do
      assert AppIcon.explain({:not_square, 1200, 300}) =~ "1200×300"
      assert AppIcon.explain({:too_small, 256}) =~ "256×256"
      assert AppIcon.explain({:too_small, 256}) =~ "#{AppIcon.min_edge()}"
    end

    test "every reason the type admits has a string" do
      # A missing clause here is a FunctionClauseError raised inside a settings
      # save, which is a 500 on a form submission. This list is the whole of
      # `@type reason` — if you add a reason, add it here and give it a clause.
      reasons = [
        :not_configured,
        :not_allowed,
        :not_in_media_library,
        :unreachable,
        :too_large,
        :not_an_image,
        {:not_square, 2, 1},
        {:too_small, 1}
      ]

      for reason <- reasons do
        assert is_binary(AppIcon.explain(reason)), "no explanation for #{inspect(reason)}"
      end
    end
  end

  describe "min_edge/0" do
    test "is 512 — the largest size a manifest declares" do
      assert AppIcon.min_edge() == 512
    end
  end
end
