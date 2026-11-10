defmodule KilnCMSWeb.ArtifactControllerTest do
  @moduledoc "Headless fired-artifact delivery (Kiln v2 — D9)."
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.TypedFixtures

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "art-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_page do
    actor = admin()
    slug = "art-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(
        %{
          title: "Headless",
          slug: slug,
          blocks:
            typed_blocks([
              %{type: :heading, content: "Welcome", data: %{"level" => 1}, order: 0},
              %{type: :image, data: %{"url" => "/p.png", "alt" => "pic"}, order: 1}
            ])
        },
        actor: actor
      )

    CMS.publish_page!(page, actor: actor)
    # Firing is async (#201): run the enqueued FireWorker so the artifact is
    # stored before the request, otherwise the API answers 503 (#208).
    KilnCMS.DataCase.drain_oban()
    slug
  end

  test "serves the json artifact for published content", %{conn: conn} do
    slug = published_page()
    body = conn |> get(~p"/api/content/page/#{slug}") |> json_response(200)

    assert body["type"] == "page"
    assert body["title"] == "Headless"
    assert [%{"_type" => "heading"} | _] = body["blocks"]
  end

  test "includes CDN cache headers and honours If-None-Match (#188)", %{conn: conn} do
    slug = published_page()

    served = get(conn, ~p"/api/content/page/#{slug}")
    assert json_response(served, 200)
    assert ["public, max-age=300"] = get_resp_header(served, "cache-control")
    assert [etag] = get_resp_header(served, "etag")
    # Weak, so Bandit still gzips it (`ArtifactCompressionTest`).
    assert etag =~ ~r/^W\/".+"$/
    assert [_last_modified] = get_resp_header(served, "last-modified")
    # The site's surrogate key, so a `KILN_CDN_PURGE_URL` purge reaches it.
    assert [keys] = get_resp_header(served, "surrogate-key")
    assert keys =~ "kiln-org-"

    # Revalidating with the same ETag returns 304 with an empty body.
    not_modified =
      build_conn()
      |> put_req_header("if-none-match", etag)
      |> get(~p"/api/content/page/#{slug}")

    assert not_modified.status == 304
    assert not_modified.resp_body == ""
  end

  test "serves the json_ld surface as a schema.org graph", %{conn: conn} do
    slug = published_page()
    body = conn |> get(~p"/api/content/page/#{slug}?surface=json_ld") |> json_response(200)

    assert body["@context"] == "https://schema.org"
    types = Enum.map(body["@graph"], & &1["@type"])
    # Pages fire a WebPage main node (#357, GEO).
    assert "WebPage" in types
    assert "ImageObject" in types
  end

  # #197: the artifact endpoint serves a specific locale via ?locale=.
  test "serves a locale-specific artifact via ?locale=", %{conn: conn} do
    actor = admin()
    slug = "art-loc-#{System.unique_integer([:positive])}"

    fr =
      CMS.create_page!(%{title: "Bonjour", slug: slug, locale: "fr"}, actor: actor)

    CMS.publish_page!(fr, actor: actor)
    KilnCMS.DataCase.drain_oban()

    body = conn |> get(~p"/api/content/page/#{slug}?locale=fr") |> json_response(200)
    assert body["title"] == "Bonjour"

    # The default locale has no such slug → 404.
    assert conn |> get(~p"/api/content/page/#{slug}?locale=en") |> json_response(404)
  end

  test "404s for unknown type, unknown slug, and unpublished content", %{conn: conn} do
    assert conn |> get(~p"/api/content/widget/whatever") |> json_response(404)
    assert conn |> get(~p"/api/content/page/does-not-exist") |> json_response(404)

    draft =
      CMS.create_page!(%{title: "Draft", slug: "art-draft-#{System.unique_integer([:positive])}"},
        actor: admin()
      )

    assert conn |> get(~p"/api/content/page/#{draft.slug}") |> json_response(404)
  end

  test "503s with Retry-After while a published artifact is still compiling", %{conn: conn} do
    actor = admin()
    slug = "art-bf-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(%{title: "Pending", slug: slug, blocks: []}, actor: actor)

    # Publish but do NOT drain — the FireWorker hasn't run, so no artifact yet.
    CMS.publish_page!(page, actor: actor)

    conn = get(conn, ~p"/api/content/page/#{slug}")

    assert %{"errors" => [%{"code" => "artifact_compiling", "status" => "503"}]} =
             json_response(conn, 503)

    assert ["2"] = get_resp_header(conn, "retry-after")

    # Once the background firing runs, the artifact is served.
    KilnCMS.DataCase.drain_oban()
    assert conn |> recycle() |> get(~p"/api/content/page/#{slug}") |> json_response(200)
  end

  describe "the ETag is a digest of the body served (#2463)" do
    alias KilnCMS.Firing.Cache
    alias KilnCMS.SystemActor

    defp org_id, do: KilnCMS.Accounts.default_org_id()

    defp page_id(slug) do
      %{rows: [[id]]} =
        Ecto.Adapters.SQL.query!(KilnCMS.Repo, "SELECT id FROM pages WHERE slug = $1", [slug])

      Ecto.UUID.cast!(id)
    end

    defp updated_at(id) do
      %{rows: [[at]]} =
        Ecto.Adapters.SQL.query!(KilnCMS.Repo, "SELECT updated_at FROM pages WHERE id = $1", [
          Ecto.UUID.dump!(id)
        ])

      at
    end

    # A re-fire as an overlay asks for one (`KilnCMS.Firing.refire/3`): the
    # stored artifact is rewritten and the document's timestamps are not.
    defp refire(id) do
      KilnCMS.Firing.refire!("page", [id], actor: SystemActor.new(:overlay), tenant: org_id())
      KilnCMS.DataCase.drain_oban()
    end

    defp fetch(slug, etag \\ nil, query \\ "") do
      conn = if etag, do: put_req_header(build_conn(), "if-none-match", etag), else: build_conn()
      get(conn, "/api/content/page/#{slug}#{query}")
    end

    defp etag(conn), do: conn |> get_resp_header("etag") |> List.first()

    test "names the record, locale and surface beside the digest" do
      slug = published_page()
      id = page_id(slug)

      assert etag(fetch(slug)) =~ ~r/^W\/"#{id}-en-json-b[A-Za-z0-9_-]{16}"$/
    end

    test "a body rewritten without updated_at moving no longer revalidates" do
      slug = published_page()
      id = page_id(slug)
      before = etag(fetch(slug))
      edited_at = updated_at(id)

      retitle_and_refire(id, "Re-rendered")
      assert updated_at(id) == edited_at

      served = fetch(slug, before)
      assert json_response(served, 200)["title"] == "Re-rendered"
      assert [after_refire] = get_resp_header(served, "etag")
      refute after_refire == before

      assert fetch(slug, after_refire).status == 304
    end

    test "a re-fire that changed nothing keeps the ETag" do
      slug = published_page()
      before = etag(fetch(slug))

      refire(page_id(slug))

      assert fetch(slug, before).status == 304
      assert etag(fetch(slug)) == before
    end

    test "is the same whether the body was cached by a fire or read from the table" do
      slug = published_page()
      id = page_id(slug)

      # More than 32 keys, so the map is not sorted on encode; atom and string
      # keys, and DateTimes, as a fire's own map may carry before the table
      # has turned it into JSON.
      body =
        Map.new(1..20, &{:"atom_key_#{&1}", DateTime.from_unix!(1_700_000_000 + &1)})
        |> Map.merge(Map.new(1..20, &{"string_key_#{&1}", %{nested: &1}}))
        |> Map.merge(%{"id" => id, "type" => "page", "title" => "Wide"})

      {:ok, _} =
        KilnCMS.Firing.upsert_artifact(
          %{
            document_type: :page,
            document_id: id,
            surface: :json,
            format_version: KilnCMS.Firing.Engine.format_version(),
            body: body,
            fired_at: DateTime.utc_now()
          },
          actor: SystemActor.new(:firing),
          tenant: org_id()
        )

      # What `Engine.persist_surface/6` does after the upsert.
      Cache.put(org_id(), :page, id, :json, body)
      from_fire = etag(fetch(slug))

      Cache.evict(org_id(), :page, id)
      from_table = fetch(slug)
      assert json_response(from_table, 200)["title"] == "Wide"
      assert etag(from_table) == from_fire

      # And again, now that the table read has warmed the cache.
      assert etag(fetch(slug)) == from_fire
    end

    # The stored tree changes under the artifact without an action, which is
    # what a deploy that changes rendering looks like to a stored artifact.
    defp retitle_and_refire(id, title) do
      Ecto.Adapters.SQL.query!(KilnCMS.Repo, "UPDATE pages SET title = $1 WHERE id = $2", [
        title,
        Ecto.UUID.dump!(id)
      ])

      refire(id)
    end

    test "the llm surface digests its Markdown: stable until the Markdown changes" do
      slug = published_page()
      id = page_id(slug)
      served = fetch(slug, nil, "?surface=llm")

      assert response(served, 200) =~ "Welcome"
      assert [tag] = get_resp_header(served, "etag")
      assert tag =~ ~r/^W\/"#{id}-en-llm-b[A-Za-z0-9_-]{16}"$/

      # A re-fire that changed nothing still revalidates…
      refire(id)
      assert fetch(slug, tag, "?surface=llm").status == 304

      # …and one that changed the Markdown does not.
      retitle_and_refire(id, "Re-rendered")
      moved = fetch(slug, tag, "?surface=llm")
      assert response(moved, 200) =~ "Re-rendered"
      refute etag(moved) == tag
    end

    test "a ?fields= response moves when a re-fire changes a field it kept" do
      slug = published_page()
      id = page_id(slug)
      tag = etag(fetch(slug, nil, "?fields=title"))

      refire(id)
      assert fetch(slug, tag, "?fields=title").status == 304

      retitle_and_refire(id, "Re-rendered")
      moved = fetch(slug, tag, "?fields=title")
      assert json_response(moved, 200)["title"] == "Re-rendered"
      refute etag(moved) == tag
    end
  end
end
