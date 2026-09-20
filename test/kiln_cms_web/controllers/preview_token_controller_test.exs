defmodule KilnCMSWeb.PreviewTokenControllerTest do
  @moduledoc """
  `POST /api/content/:type/:id/preview-token` — minting a draft preview link
  over the API, for a headless front end's draft mode. Before this route (and
  the editor's Copy preview link) nothing outside the tests ever called
  `PreviewToken.sign/1`, so `GET /preview/:token` had no way to be used.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  defp user(role, extra \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "ptc-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        extra
      )
    )
  end

  # A `:read` key: minting is distribution of a read, never a write, so the
  # read-only scope a headless front end should hold is enough.
  defp key(owner, access \\ :read) do
    owner.id
    |> Accounts.mint_api_key!(
      "ptc",
      DateTime.add(DateTime.utc_now(), 30, :day),
      %{access: access},
      actor: user(:admin)
    )
    |> Ash.Resource.get_metadata(:plaintext_api_key)
  end

  defp slug, do: "ptc-#{System.unique_integer([:positive])}"

  defp draft_page(actor, attrs \\ %{}),
    do: CMS.create_page!(Map.merge(%{title: "Draft title", slug: slug()}, attrs), actor: actor)

  defp mint(conn, type, id, bearer) do
    conn
    |> put_req_header("accept", "application/json")
    |> then(&if(bearer, do: put_req_header(&1, "authorization", "Bearer #{bearer}"), else: &1))
    |> post("/api/content/#{type}/#{id}/preview-token")
  end

  defp redeem(token, conn \\ build_conn()),
    do: conn |> put_req_header("accept", "application/json") |> get("/preview/#{token}")

  test "an editor's read key mints a link that serves the draft", %{conn: conn} do
    editor = user(:editor)
    page = draft_page(editor, %{title: "Not yet public"})

    conn = mint(conn, "page", page.id, key(editor))

    assert %{
             "token" => token,
             "url" => url,
             "type" => "page",
             "id" => id,
             "expires_at" => expires_at,
             "expires_in" => 900
           } = json_response(conn, 201)

    assert id == page.id
    assert url == KilnCMSWeb.Tenant.base_url(page.org_id) <> "/preview/" <> token
    assert {:ok, _, _} = DateTime.from_iso8601(expires_at)
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]

    # The whole point: the token is redeemable, by someone holding nothing else.
    assert %{"data" => %{"id" => ^id, "title" => "Not yet public", "state" => "draft"}} =
             json_response(redeem(token), 200)
  end

  test "a live document's link serves its unpublished working copy", %{conn: conn} do
    admin = user(:admin)
    page = draft_page(admin, %{title: "Published title"})
    page = CMS.publish_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()
    page = CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

    {:ok, _} =
      CMS.save_page_working_copy(page, %{working_title: "Edited, not published"},
        actor: admin,
        tenant: page.org_id
      )

    %{"token" => token} = conn |> mint("page", page.id, key(admin)) |> json_response(201)

    assert %{"data" => %{"title" => "Edited, not published"}} = json_response(redeem(token), 200)
  end

  test "anonymous callers are refused with 401", %{conn: conn} do
    page = draft_page(user(:admin))

    assert %{"errors" => [%{"status" => "401", "code" => "unauthorized"}]} =
             conn |> mint("page", page.id, nil) |> json_response(401)
  end

  test "an invalid key is anonymous, and refused the same way", %{conn: conn} do
    page = draft_page(user(:admin))

    assert conn |> mint("page", page.id, "kiln_not_a_real_key") |> json_response(401)
  end

  test "a viewer's key: 403 on a live document, 404 on a draft", %{conn: conn} do
    admin = user(:admin)
    viewer_key = key(user(:viewer))

    live = admin |> draft_page() |> CMS.publish_page!(%{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             conn |> mint("page", live.id, viewer_key) |> json_response(403)

    assert %{"errors" => [%{"code" => "not_found"}]} =
             build_conn() |> mint("page", draft_page(admin).id, viewer_key) |> json_response(404)
  end

  test "unknown types and ids are 404", %{conn: conn} do
    admin = user(:admin)
    k = key(admin)

    assert conn |> mint("nope", Ecto.UUID.generate(), k) |> json_response(404)
    assert build_conn() |> mint("page", Ecto.UUID.generate(), k) |> json_response(404)
  end

  test "on a tenant's host the link points at that host, and only works there" do
    admin = user(:admin)
    org = KilnCMS.OrgFixtures.org("ptc")

    page =
      CMS.create_page!(%{title: "Tenant draft", slug: slug()}, actor: admin, tenant: org.id)

    conn = build_conn() |> org_conn(org) |> mint("page", page.id, key(admin))
    assert %{"token" => token, "url" => url} = json_response(conn, 201)

    assert URI.parse(url).host == "#{org.slug}.#{KilnCMSWeb.Tenant.base_host()}"
    assert json_response(redeem(token, build_conn() |> org_conn(org)), 200)
    # The default site's host refuses another site's draft (#1309).
    assert json_response(redeem(token), 404)
  end

  test "an admin-defined type round-trips by its own name", %{conn: conn} do
    admin = user(:admin)

    definition =
      CMS.create_type_definition!(
        %{name: "ptc#{System.unique_integer([:positive])}", label: "Recipe"},
        actor: admin
      )

    entry = ContentTypes.create!(definition.name, %{title: "Soup", slug: slug()}, actor: admin)

    %{"token" => token, "type" => type} =
      conn |> mint(definition.name, entry.id, key(admin)) |> json_response(201)

    assert type == definition.name
    assert %{"data" => %{"title" => "Soup"}} = json_response(redeem(token), 200)
  end
end
