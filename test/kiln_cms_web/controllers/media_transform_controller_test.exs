defmodule KilnCMSWeb.MediaTransformControllerTest do
  @moduledoc """
  `GET /media/:id/t/:ops` end to end: real renders from stored originals, the
  cache headers that make a versioned URL immutable, the refusals for every
  way a request can be out of bounds, and the same visibility as
  `/media/:id/download` — a gated or quarantined item is a 404 to anyone its
  download would 404 for.
  """
  # async: false — Storage.Local, `:image_transforms` and the rate-limit
  # config all live in the global app env.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Media.ImageTransform
  alias KilnCMS.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_txc_#{System.unique_integer([:positive])}")
    private_root = root <> "_private"
    File.mkdir_p!(root)
    File.mkdir_p!(private_root)

    Application.put_env(:kiln_cms, KilnCMS.Storage.Local,
      root: root,
      private_root: private_root,
      base_url: "/uploads"
    )

    previous = Application.get_env(:kiln_cms, :image_transforms)
    Application.put_env(:kiln_cms, :image_transforms, signing_key: "controller-test-key")
    KilnCMS.RateLimitHelpers.restore_limits_on_exit()

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(private_root)
      Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
      restore(:image_transforms, previous)
    end)

    %{root: root}
  end

  defp restore(key, nil), do: Application.delete_env(:kiln_cms, key)
  defp restore(key, value), do: Application.put_env(:kiln_cms, key, value)

  defp stored_png(width, height, opts) do
    src = Path.join(System.tmp_dir!(), "txc-#{System.unique_integer([:positive])}.png")
    {:ok, image} = Image.new(width, height, color: :green)
    {:ok, _} = Image.write(image, src)
    key = "orig-#{System.unique_integer([:positive])}.png"

    {:ok, ^key} =
      if opts[:private], do: Storage.store_private(key, src), else: Storage.store(key, src)

    File.rm(src)
    key
  end

  defp image!(attrs \\ %{}) do
    key = stored_png(1200, 800, private: attrs[:audience] not in [nil, :public])

    Ash.Seed.seed!(
      KilnCMS.CMS.MediaItem,
      Map.merge(
        %{
          filename: "hero.png",
          url: "/uploads/#{key}",
          storage_key: key,
          content_type: "image/png",
          width: 1200,
          height: 800,
          focal_x: 0.5,
          focal_y: 0.5
        },
        attrs
      )
    )
  end

  defp decoded(conn) do
    {:ok, image} = Image.from_binary(conn.resp_body)
    {Image.width(image), Image.height(image)}
  end

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  describe "a public image" do
    test "renders anonymously at the requested size, then serves the cached copy", %{conn: conn} do
      item = image!()
      path = "/media/#{item.id}/t/w_640"

      first = get(conn, path)
      assert first.status == 200
      assert header(first, "content-type") == "image/png"
      assert header(first, "x-kiln-transform") == "miss"
      assert header(first, "x-content-type-options") == "nosniff"
      # A Set-Cookie would make a shared cache refuse to store the image.
      assert get_resp_header(first, "set-cookie") == []
      assert decoded(first) == {640, 427}

      second = get(build_conn(), path)
      assert second.status == 200
      assert header(second, "x-kiln-transform") == "hit"
      assert second.resp_body == first.resp_body
    end

    test "a URL pinned to the current version is immutable for a year", %{conn: conn} do
      item = image!()
      conn = get(conn, "/media/#{item.id}/t/w_640,v_#{ImageTransform.version(item)}")

      assert conn.status == 200
      assert header(conn, "cache-control") == "public, max-age=31536000, immutable"
    end

    test "without a version, or with a stale one, the lifetime is five minutes", %{conn: conn} do
      item = image!()

      assert conn |> get("/media/#{item.id}/t/w_640") |> header("cache-control") ==
               "public, max-age=300"

      assert build_conn()
             |> get("/media/#{item.id}/t/w_640,v_00000000")
             |> header("cache-control") ==
               "public, max-age=300"
    end

    test "a server-built URL (signed, versioned, any size) serves", %{conn: conn} do
      item = image!()
      conn = get(conn, ImageTransform.url(item, width: 333, aspect_ratio: "1:1", format: :webp))

      assert conn.status == 200
      assert header(conn, "content-type") == "image/webp"
      assert decoded(conn) == {333, 333}
      assert header(conn, "cache-control") =~ "immutable"
    end

    test "fm_auto picks from Accept and varies on it", %{conn: conn} do
      item = image!()

      webp =
        conn
        |> put_req_header("accept", "image/avif,image/webp,*/*")
        |> get("/media/#{item.id}/t/w_256,fm_auto")

      assert webp.status == 200
      assert header(webp, "content-type") == "image/webp"
      assert header(webp, "vary") == "Accept"

      fallback =
        build_conn()
        |> put_req_header("accept", "image/png")
        |> get("/media/#{item.id}/t/w_256,fm_auto")

      assert header(fallback, "content-type") == "image/png"
    end

    test "an image-only Accept header is not refused as unacceptable", %{conn: conn} do
      item = image!()
      conn = conn |> put_req_header("accept", "image/avif") |> get("/media/#{item.id}/t/w_256")
      assert conn.status == 200
    end

    test "If-None-Match with the ETag is a 304 with no body", %{conn: conn} do
      item = image!()
      path = "/media/#{item.id}/t/w_256"
      etag = conn |> get(path) |> header("etag")
      assert etag =~ ~r/\A"t-[0-9a-f]{32}"\z/

      revalidated = build_conn() |> put_req_header("if-none-match", etag) |> get(path)
      assert revalidated.status == 304
      assert revalidated.resp_body == ""
    end
  end

  describe "refusals" do
    test "a malformed transform is a 400 in plain text", %{conn: conn} do
      item = image!()
      conn = get(conn, "/media/#{item.id}/t/w_abc")

      assert conn.status == 400
      assert header(conn, "content-type") =~ "text/plain"
      assert header(conn, "cache-control") == "no-store"
    end

    test "an unsigned size off the allowlist is a 400 that says what would work", %{conn: conn} do
      item = image!()
      conn = get(conn, "/media/#{item.id}/t/w_641")

      assert conn.status == 400
      assert conn.resp_body =~ "needs a signed URL"
      assert conn.resp_body =~ "640"
    end

    test "a bad signature is a 403", %{conn: conn} do
      item = image!()
      conn = get(conn, "/media/#{item.id}/t/w_641,s_AAAAAAAAAAAAAAAAAAAAAA")
      assert conn.status == 403
    end

    test "with unsigned URLs turned off, only signed ones serve", %{conn: conn} do
      Application.put_env(:kiln_cms, :image_transforms,
        signing_key: "controller-test-key",
        allow_unsigned: false
      )

      item = image!()
      assert get(conn, "/media/#{item.id}/t/w_640").status == 403
      assert get(build_conn(), ImageTransform.url(item, width: 640)).status == 200
    end

    test "a refused request never reads the item", %{conn: conn} do
      # An id that doesn't exist, but the request is refused on its parameters
      # first — so the answer is the parameter error, not a 404.
      conn = get(conn, "/media/#{Ecto.UUID.generate()}/t/w_641")
      assert conn.status == 400
    end

    test "an unknown or malformed id is a 404", %{conn: conn} do
      assert get(conn, "/media/#{Ecto.UUID.generate()}/t/w_640").status == 404
      assert get(build_conn(), "/media/not-a-uuid/t/w_640").status == 404
    end

    test "a document is a 422", %{conn: conn} do
      key = Storage.generate_key("brochure.pdf")
      src = Path.join(System.tmp_dir!(), "doc-#{System.unique_integer([:positive])}")
      File.write!(src, "%PDF-1.7")
      {:ok, ^key} = Storage.store(key, src)

      doc =
        Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
          filename: "brochure.pdf",
          content_type: "application/pdf",
          storage_key: key,
          url: Storage.url(key)
        })

      assert get(conn, "/media/#{doc.id}/t/w_640").status == 422
    end

    test "a source over the pixel cap is a 422 before it is decoded", %{conn: conn} do
      Application.put_env(:kiln_cms, :image_transforms,
        signing_key: "controller-test-key",
        max_source_pixels: 1_000
      )

      item = image!()
      conn = get(conn, "/media/#{item.id}/t/w_640")
      assert conn.status == 422
      assert conn.resp_body =~ "too large"
    end

    test "cache misses past the per-client render budget are a 429; hits are not", %{conn: conn} do
      # Merged into the test limits, not replacing them: a bare
      # `limits: %{media_render: …}` put every other bucket back on its
      # shipped value for the rest of the test (#1614).
      KilnCMS.RateLimitHelpers.put_limit(:media_render, 1)

      # Its own address, so no other test's renders share this budget.
      address = {10, 99, 0, rem(System.unique_integer([:positive]), 250) + 1}
      item = image!()
      at = fn path -> %{build_conn() | remote_ip: address} |> get(path) end

      assert at.("/media/#{item.id}/t/w_256").status == 200
      denied = at.("/media/#{item.id}/t/w_384")
      assert denied.status == 429
      assert header(denied, "retry-after")

      # Already cached: a read, not a render, so the budget doesn't apply.
      assert at.("/media/#{item.id}/t/w_256").status == 200
      _ = conn
    end
  end

  describe "visibility matches /media/:id/download" do
    defp signed_in_user(attrs) do
      email = "tx-#{System.unique_integer([:positive])}@example.com"

      Ash.Seed.seed!(
        User,
        Map.merge(
          %{
            email: email,
            hashed_password: Bcrypt.hash_pwd_salt("password123456"),
            confirmed_at: DateTime.utc_now()
          },
          attrs
        )
      )

      strategy = AshAuthentication.Info.strategy!(User, :password)

      {:ok, user} =
        AshAuthentication.Strategy.action(
          strategy,
          :sign_in,
          %{
            "email" => email,
            "password" => "password123456"
          },
          []
        )

      user
    end

    defp log_in(conn, user) do
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
    end

    test "a gated item is a 404 anonymously and without the audience", %{conn: conn} do
      item = image!(%{audience: :member})

      assert get(conn, "/media/#{item.id}/t/w_640").status == 404

      assert build_conn()
             |> log_in(signed_in_user(%{role: :viewer, audiences: []}))
             |> get("/media/#{item.id}/t/w_640")
             |> Map.fetch!(:status) == 404
    end

    test "a gated item renders from private storage for a holder, never publicly cached", %{
      conn: conn
    } do
      item = image!(%{audience: :member})

      conn =
        conn
        |> log_in(
          %{role: :viewer}
          |> signed_in_user()
          |> KilnCMS.OrgFixtures.grant_audiences([:member])
        )
        |> get("/media/#{item.id}/t/w_640,v_#{ImageTransform.version(item)}")

      assert conn.status == 200
      assert decoded(conn) == {640, 427}
      assert header(conn, "cache-control") == "private, no-store"
    end

    test "a holder whose session is past the site's idle timeout gets nothing, and nothing is written",
         %{conn: conn} do
      item = image!(%{audience: :member})
      org_id = KilnCMS.Accounts.default_org_id()

      KilnCMS.CMS.save_site_session_policy!(%{idle_timeout_minutes: 15},
        authorize?: false,
        tenant: org_id
      )

      KilnCMS.Repo.query!(
        "UPDATE site_session_policy SET policy_changed_at = (now() AT TIME ZONE 'utc') - interval '1 day' WHERE org_id = $1",
        [Ecto.UUID.dump!(org_id)]
      )

      KilnCMS.Cache.bust_session_policy(org_id)

      holder =
        %{role: :viewer} |> signed_in_user() |> KilnCMS.OrgFixtures.grant_audiences([:member])

      conn = log_in(conn, holder)
      jti = KilnCMS.Accounts.Token.peeked_jti(get_session(conn, :user_token))
      url = "/media/#{item.id}/t/w_640,v_#{ImageTransform.version(item)}"

      # Active: the image.
      assert get(conn, url).status == 200

      KilnCMS.Repo.query!(
        "UPDATE tokens SET last_used_at = (now() AT TIME ZONE 'utc') - interval '1 hour' WHERE jti = $1",
        [jti]
      )

      idle = get(conn, url)
      assert idle.status == 404
      assert get_resp_header(idle, "set-cookie") == []
      # Read only: the row is not revoked here, nor touched.
      assert %{purpose: "user"} =
               KilnCMS.Accounts.IdleTimeout.read(jti, KilnCMS.Accounts.IdleTimeout.off())
               |> elem(1)
    end

    test "a holder whose session predates the site's sign-out-everyone gets nothing", %{
      conn: conn
    } do
      item = image!(%{audience: :member})
      org_id = KilnCMS.Accounts.default_org_id()

      holder =
        %{role: :viewer} |> signed_in_user() |> KilnCMS.OrgFixtures.grant_audiences([:member])

      conn = log_in(conn, holder)
      url = "/media/#{item.id}/t/w_640,v_#{ImageTransform.version(item)}"
      assert get(conn, url).status == 200

      KilnCMS.CMS.record_sessions_revoked!(%{at: DateTime.add(DateTime.utc_now(), 60)},
        authorize?: false,
        tenant: org_id
      )

      KilnCMS.Cache.bust_session_policy(org_id)
      on_exit(fn -> KilnCMS.Cache.bust_session_policy(org_id) end)

      assert get(conn, url).status == 404
    end

    test "a quarantined item is a 404 even to an editor", %{conn: conn} do
      item = image!(%{quarantined: true})

      conn =
        conn
        |> log_in(signed_in_user(%{role: :editor}))
        |> get("/media/#{item.id}/t/w_640")

      assert conn.status == 404
    end

    test "a trashed item is a 404", %{conn: conn} do
      item = image!()
      :ok = CMS.destroy_media_item(item, authorize?: false)
      assert get(conn, "/media/#{item.id}/t/w_640").status == 404
    end
  end

  describe "an image backend's item (#1955)" do
    alias KilnCMS.FixturePlugin.ImageBackend, as: Fixture

    setup do
      on_exit(fn -> Application.delete_env(:kiln_cms, :fixture_image_backend) end)
    end

    defp backend_image! do
      src = Path.join(System.tmp_dir!(), "txc-#{System.unique_integer([:positive])}.png")
      {:ok, image} = Image.new(1200, 800, color: :green)
      {:ok, _} = Image.write(image, src)
      key = "orig-#{System.unique_integer([:positive])}.png"
      {:ok, ^key} = Fixture.store(key, src)
      File.rm(src)

      Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
        filename: "hero.png",
        url: Fixture.url(key),
        storage_key: key,
        content_type: "image/png",
        width: 1200,
        height: 800,
        image_backend: Fixture.name()
      })
    end

    test "redirects to the backend's rendering, with the headers the bytes would carry",
         %{conn: conn} do
      item = backend_image!()
      conn = get(conn, "/media/#{item.id}/t/w_640,v_#{ImageTransform.version(item)}")

      assert conn.status == 302

      assert header(conn, "location") ==
               "https://images.fixture.test/#{item.storage_key}/w=640,h=427,f=png"

      assert header(conn, "x-kiln-transform") == "backend"
      assert header(conn, "cache-control") == "public, max-age=31536000, immutable"
      assert header(conn, "etag")
      assert header(conn, "content-type") == nil
      # Nothing was rendered, so nothing was kept.
      assert CMS.list_media_derivatives!(item.id, authorize?: false) == []
    end

    # Signing and the allowlist are Kiln's to enforce: a backend URL that
    # answered any size would make the allowlist advisory.
    test "an unsigned size off the allowlist is refused before any redirect", %{conn: conn} do
      item = backend_image!()
      conn = get(conn, "/media/#{item.id}/t/w_641")

      assert conn.status == 400
      assert conn.resp_body =~ "needs a signed URL"
      assert header(conn, "location") == nil
    end

    test "a backend that can't render it is rendered here, from the backend's original",
         %{conn: conn} do
      Application.put_env(:kiln_cms, :fixture_image_backend, renders?: false)
      item = backend_image!()

      conn = get(conn, "/media/#{item.id}/t/w_640")

      assert conn.status == 200
      assert header(conn, "x-kiln-transform") == "miss"
      assert decoded(conn) == {640, 427}
    end
  end
end
