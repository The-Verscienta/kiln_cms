defmodule KilnCMSWeb.ContentLockTest do
  @moduledoc """
  Passphrase-locked published content (#496) across both delivery surfaces, and
  the exclusion sweep the issue calls the real work.

  The exclusion tests are the load-bearing ones. A lock that keeps a visitor off
  the page while the same text sits in the sitemap, a feed, the search index or
  a related-content response is not weak protection — it is none, arrived at
  quietly.
  """
  use KilnCMSWeb.ConnCase, async: false

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentPassword
  alias KilnCMSWeb.ContentLock

  @passphrase "let me in please"
  @secret_body "The confidential proposal body"

  setup do
    %{org_id: KilnCMS.Accounts.default_org_id(), actor: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "lock-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "lock-#{System.unique_integer([:positive])}"

  defp secret_block do
    %{
      "_type" => "rich_text",
      "_id" => Ash.UUID.generate(),
      "body" => [
        %{
          "_type" => "block",
          "_key" => "b0",
          "children" => [%{"_type" => "span", "text" => @secret_body, "marks" => []}]
        }
      ]
    }
  end

  defp published_page(actor, attrs \\ %{}) do
    page =
      CMS.create_page!(
        Map.merge(
          %{
            title: "Client proposal",
            slug: slug(),
            block_tree: [secret_block()]
          },
          attrs
        ),
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    KilnCMS.DataCase.drain_oban()
    Ash.reload!(page, authorize?: false, tenant: page.org_id)
  end

  defp locked_page(ctx, attrs \\ %{}) do
    published_page(ctx.actor, Map.put(attrs, :access_password, @passphrase))
  end

  defp unlock(conn, page, passphrase) do
    post(conn, "/_unlock", %{
      "path" => "/#{page.slug}",
      "type" => "page",
      "locale" => page.locale,
      "passphrase" => passphrase
    })
  end

  # ── The built-in site ───────────────────────────────────────────────────────

  describe "the rendered site" do
    test "an unlocked visitor gets the passphrase form, not the document", ctx do
      page = locked_page(ctx)

      conn = get(ctx.conn, "/#{page.slug}")

      assert conn.status == 401
      body = html_response(conn, 401)
      refute body =~ @secret_body
      assert body =~ "passphrase"
      # The title is deliberately shown: a lock page has to be recognisable as
      # the page you were sent, or the passphrase is unusable.
      assert body =~ "Client proposal"
    end

    test "the right passphrase unlocks the document", ctx do
      page = locked_page(ctx)

      conn = unlock(ctx.conn, page, @passphrase)
      assert redirected_to(conn, 303) == "/#{page.slug}"

      body = conn |> recycle() |> get("/#{page.slug}") |> html_response(200)
      assert body =~ @secret_body
    end

    test "a wrong passphrase re-renders the form and grants nothing", ctx do
      page = locked_page(ctx)

      conn = unlock(ctx.conn, page, "wrong")

      assert conn.status == 401
      refute html_response(conn, 401) =~ @secret_body
      assert ContentLock.grants(conn) == []
    end

    test "an unlocked document is unaffected", ctx do
      page = published_page(ctx.actor)

      assert ctx.conn |> get("/#{page.slug}") |> html_response(200) =~ @secret_body
    end

    test "a grant for one document does not unlock another", ctx do
      one = locked_page(ctx)
      two = locked_page(ctx)

      conn = ctx.conn |> unlock(one, @passphrase) |> recycle()

      assert conn |> get("/#{two.slug}") |> html_response(401)
    end

    test "rotating the passphrase locks an already-unlocked visitor out", ctx do
      page = locked_page(ctx)
      conn = ctx.conn |> unlock(page, @passphrase) |> recycle()
      assert conn |> recycle() |> get("/#{page.slug}") |> html_response(200)

      page
      |> Ash.reload!(authorize?: false, tenant: page.org_id)
      |> CMS.update_page!(%{access_password: "a different passphrase"}, actor: ctx.actor)

      # The grant names the passphrase's fingerprint, so rotation invalidates it
      # inside the read filter — there is no separate revocation step to forget.
      assert conn |> recycle() |> get("/#{page.slug}") |> html_response(401)
    end
  end

  describe "caching" do
    test "an unlocked render is never shared-cached", ctx do
      page = locked_page(ctx)

      conn =
        ctx.conn
        |> unlock(page, @passphrase)
        |> recycle()
        |> get("/#{page.slug}")

      cache_control = conn |> get_resp_header("cache-control") |> List.first()

      # With `public, max-age=60` the first unlocked visitor would populate a
      # shared cache and the next minute of anonymous visitors would read the
      # document without ever seeing the lock page.
      assert cache_control =~ "private"
      assert cache_control =~ "no-store"
      assert get_resp_header(conn, "etag") == []
    end

    test "the lock page is not shared-cached and is not indexable", ctx do
      page = locked_page(ctx)

      conn = get(ctx.conn, "/#{page.slug}")

      assert conn |> get_resp_header("cache-control") |> List.first() =~ "no-store"
      assert conn |> get_resp_header("x-robots-tag") |> List.first() =~ "noindex"
    end
  end

  describe "the unlock endpoint" do
    test "refuses an off-site return path", ctx do
      page = locked_page(ctx)

      conn =
        post(ctx.conn, "/_unlock", %{
          "path" => "//evil.example.com",
          "type" => "page",
          "locale" => page.locale,
          "passphrase" => @passphrase
        })

      assert conn.status == 404
    end

    test "answers the same for an unlocked document as for a wrong passphrase", ctx do
      unlocked = published_page(ctx.actor)

      conn = unlock(ctx.conn, unlocked, @passphrase)

      # Otherwise the endpoint enumerates which documents are locked.
      assert conn.status == 404
    end
  end

  # ── The headless surface ────────────────────────────────────────────────────

  describe "headless delivery" do
    test "answers 401 password_required rather than 404", ctx do
      page = locked_page(ctx)

      conn = get(ctx.conn, "/api/content/page/#{page.slug}")

      assert %{"errors" => [%{"code" => "password_required"}]} = json_response(conn, 401)
      assert conn |> get_resp_header("cache-control") |> List.first() =~ "no-store"
    end

    test "a token minted from the passphrase reads the document", ctx do
      page = locked_page(ctx)

      %{"token" => token} =
        ctx.conn
        |> post("/api/content/page/#{page.slug}/unlock", %{"passphrase" => @passphrase})
        |> json_response(200)

      body =
        ctx.conn
        |> put_req_header("x-kiln-unlock", token)
        |> get("/api/content/page/#{page.slug}")
        |> json_response(200)

      assert inspect(body) =~ @secret_body
    end

    test "an unlocked artifact response is never shared-cached", ctx do
      page = locked_page(ctx)

      %{"token" => token} =
        ctx.conn
        |> post("/api/content/page/#{page.slug}/unlock", %{"passphrase" => @passphrase})
        |> json_response(200)

      conn =
        ctx.conn
        |> put_req_header("x-kiln-unlock", token)
        |> get("/api/content/page/#{page.slug}")

      assert conn |> get_resp_header("cache-control") |> List.first() =~ "no-store"
      assert get_resp_header(conn, "etag") == []
    end

    test "a token for one document does not read another", ctx do
      one = locked_page(ctx)
      two = locked_page(ctx)

      %{"token" => token} =
        ctx.conn
        |> post("/api/content/page/#{one.slug}/unlock", %{"passphrase" => @passphrase})
        |> json_response(200)

      conn =
        ctx.conn
        |> put_req_header("x-kiln-unlock", token)
        |> get("/api/content/page/#{two.slug}")

      assert json_response(conn, 401)
    end

    test "a wrong passphrase mints nothing", ctx do
      page = locked_page(ctx)

      conn = post(ctx.conn, "/api/content/page/#{page.slug}/unlock", %{"passphrase" => "nope"})

      assert %{"errors" => [%{"code" => "invalid_passphrase"}]} = json_response(conn, 401)
    end

    test "a garbage grant is ignored rather than accepted or crashing", ctx do
      page = locked_page(ctx)

      conn =
        ctx.conn
        |> put_req_header("x-kiln-unlock", "not-a-token")
        |> get("/api/content/page/#{page.slug}")

      assert json_response(conn, 401)
    end
  end

  # ── The exclusion sweep ─────────────────────────────────────────────────────

  describe "exclusions" do
    test "a locked page is not in the sitemap", ctx do
      locked = locked_page(ctx)
      open = published_page(ctx.actor)

      body = ctx.conn |> get("/sitemap.xml") |> response(200)

      assert body =~ open.slug
      refute body =~ locked.slug
    end

    test "a locked post is not in the feed", ctx do
      locked =
        CMS.create_post!(
          %{
            title: "Locked post",
            slug: slug(),
            access_password: @passphrase,
            block_tree: [secret_block()]
          },
          actor: ctx.actor
        )

      CMS.publish_post!(locked, actor: ctx.actor)
      KilnCMS.DataCase.drain_oban()

      body = ctx.conn |> get("/feed.xml") |> response(200)

      refute body =~ locked.slug
      refute body =~ @secret_body
    end

    test "a locked page is not in llms.txt", ctx do
      locked = locked_page(ctx)

      body = ctx.conn |> get("/llms.txt") |> response(200)

      refute body =~ locked.slug
    end

    test "a locked page is not in on-site search", ctx do
      locked = locked_page(ctx, %{title: "Zarquon confidential"})

      body = ctx.conn |> get("/search?q=Zarquon") |> html_response(200)

      refute body =~ locked.slug
    end

    test "a locked page is not an actorless keyword-search result", ctx do
      locked = locked_page(ctx, %{title: "Zarquon confidential"})

      results = CMS.search_published_pages!("Zarquon", authorize?: true, tenant: ctx.org_id)

      refute locked.id in Enum.map(results, & &1.id)
    end

    test "an editor still reads locked content", ctx do
      locked = locked_page(ctx)

      results = CMS.search_pages!("proposal", actor: ctx.actor, tenant: ctx.org_id)

      # The lock is a *delivery* control, not an editorial one — the person who
      # set the passphrase must not lose their own document.
      assert locked.id in Enum.map(results, & &1.id)
    end

    test "a locked page is not a related-content neighbour", ctx do
      locked = locked_page(ctx)

      neighbours = KilnCMS.Search.Related.related_documents(locked, limit: 20)

      refute locked.slug in Enum.map(neighbours, & &1.slug)
    end

    test "a locked post cannot be sent as a newsletter", ctx do
      locked =
        CMS.create_post!(
          %{title: "Locked post", slug: slug(), access_password: @passphrase},
          actor: ctx.actor
        )

      CMS.publish_post!(locked, actor: ctx.actor)
      reloaded = Ash.reload!(locked, authorize?: false, tenant: ctx.org_id)

      assert {:error, :gated} = KilnCMS.Newsletter.send_as_newsletter(reloaded, actor: ctx.actor)
    end

    test "a locked document keeps no block embeddings", ctx do
      locked = locked_page(ctx)
      KilnCMS.DataCase.drain_oban()

      rows =
        KilnCMS.SearchIndex.block_embeddings_for!(:page, locked.id,
          authorize?: false,
          tenant: ctx.org_id
        )

      assert rows == []
    end
  end
end
