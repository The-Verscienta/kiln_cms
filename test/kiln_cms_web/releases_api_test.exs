defmodule KilnCMSWeb.ReleasesApiTest do
  @moduledoc """
  `/api/json/releases` and `/api/json/release-items` — content releases (#500)
  readable over JSON:API for editor-tier callers.

  Same `:read` and policies as the console: editor-or-above of the request's org
  reads, a viewer or anonymous caller gets nothing, and the host's org bounds
  what any credential can see. Read-only by construction — no write route
  exists, because shipping a release publishes as an admin.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @accept "application/vnd.api+json"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "relapi-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint(owner, access) do
    key =
      Accounts.mint_api_key!(
        owner.id,
        "releases-api",
        DateTime.add(DateTime.utc_now(), 30, :day),
        %{access: access},
        actor: user(:admin)
      )

    Ash.Resource.get_metadata(key, :plaintext_api_key)
  end

  defp req(method, path, opts \\ []) do
    conn =
      build_conn()
      |> put_req_header("accept", @accept)
      |> put_req_header("content-type", @accept)

    conn = if opts[:org], do: org_conn(conn, opts[:org]), else: conn

    conn =
      case opts[:key] do
        nil -> conn
        key -> put_req_header(conn, "authorization", "Bearer #{key}")
      end

    conn =
      case opts[:body] do
        nil -> dispatch(conn, @endpoint, method, path)
        body -> dispatch(conn, @endpoint, method, path, Jason.encode!(body))
      end

    body = if conn.resp_body == "", do: %{}, else: Jason.decode!(conn.resp_body)
    {conn.status, body}
  end

  defp ids({200, %{"data" => data}}), do: Enum.map(data, & &1["id"])

  defp slug, do: "relapi-#{System.unique_integer([:positive])}"

  setup do
    admin = user(:admin)
    release = CMS.create_release!(%{name: "Autumn launch", description: "Homepage"}, actor: admin)
    page = CMS.create_page!(%{title: "Landing", slug: slug()}, actor: admin)

    item =
      CMS.add_release_item!(
        %{release_id: release.id, content_type: "page", content_id: page.id},
        actor: admin
      )

    %{admin: admin, release: release, page: page, item: item}
  end

  describe "who can read" do
    test "an editor's read-only key lists releases with their public fields",
         %{release: release} do
      key = mint(user(:editor), :read)

      {200, %{"data" => data}} = req(:get, "/api/json/releases", key: key)
      row = Enum.find(data, &(&1["id"] == release.id))

      assert row["type"] == "release"
      assert row["attributes"]["name"] == "Autumn launch"
      assert row["attributes"]["description"] == "Homepage"
      assert row["attributes"]["state"] == "open"
      assert Map.has_key?(row["attributes"], "scheduled_at")

      # No user ids, no tenancy.
      for private <- ~w(creator_id triggered_by_id org_id) do
        refute Map.has_key?(row["attributes"], private)
      end
    end

    test "an anonymous caller gets an empty list and a 404 on the record",
         %{release: release, item: item} do
      assert {200, %{"data" => []}} = req(:get, "/api/json/releases")
      assert {404, _} = req(:get, "/api/json/releases/#{release.id}")
      assert {200, %{"data" => []}} = req(:get, "/api/json/release-items")
      assert {404, _} = req(:get, "/api/json/release-items/#{item.id}")
    end

    test "a viewer's key — even a read-write one — sees nothing", %{release: release} do
      key = mint(user(:viewer), :read_write)

      assert {200, %{"data" => []}} = req(:get, "/api/json/releases", key: key)
      assert {404, _} = req(:get, "/api/json/releases/#{release.id}", key: key)
      assert {200, %{"data" => []}} = req(:get, "/api/json/release-items", key: key)
    end

    test "another org's releases are invisible from this org's host", %{
      admin: admin,
      release: home
    } do
      other_org = KilnCMS.OrgFixtures.org("relapi")
      foreign = CMS.create_release!(%{name: "Elsewhere"}, actor: admin, tenant: other_org)
      key = mint(admin, :read)

      listed = ids(req(:get, "/api/json/releases", key: key))
      assert home.id in listed
      refute foreign.id in listed
      assert {404, _} = req(:get, "/api/json/releases/#{foreign.id}", key: key)

      there = ids(req(:get, "/api/json/releases", key: key, org: other_org))
      assert foreign.id in there
      refute home.id in there
    end
  end

  describe "items" do
    test "include=items carries what the release will do", %{
      release: release,
      page: page,
      item: item
    } do
      key = mint(user(:editor), :read)

      {200, %{"data" => data, "included" => included}} =
        req(:get, "/api/json/releases/#{release.id}?include=items", key: key)

      assert %{"relationships" => %{"items" => %{"data" => [ref]}}} = data
      assert ref == %{"type" => "release_item", "id" => item.id}

      assert [%{"type" => "release_item", "attributes" => attrs}] = included
      assert attrs["content_type"] == "page"
      assert attrs["content_id"] == page.id
      assert attrs["action"] == "publish"
      assert attrs["status"] == "pending"
      refute Map.has_key?(attrs, "added_by_id")
      refute Map.has_key?(attrs, "org_id")
    end

    test "items filter by release", %{admin: admin, release: release, item: item} do
      other = CMS.create_release!(%{name: "Other"}, actor: admin)
      page = CMS.create_page!(%{title: "Other page", slug: slug()}, actor: admin)

      other_item =
        CMS.add_release_item!(
          %{release_id: other.id, content_type: "page", content_id: page.id},
          actor: admin
        )

      key = mint(user(:editor), :read)

      listed =
        ids(req(:get, "/api/json/release-items?filter[release_id]=#{release.id}", key: key))

      assert listed == [item.id]
      refute other_item.id in listed
    end

    test "filter[state] narrows the release index", %{admin: admin, release: open} do
      scheduled =
        %{name: "Later"}
        |> CMS.create_release!(actor: admin)
        |> CMS.schedule_release!(%{scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day)},
          actor: admin
        )

      key = mint(user(:editor), :read)
      listed = ids(req(:get, "/api/json/releases?filter[state]=scheduled", key: key))

      assert scheduled.id in listed
      refute open.id in listed
    end
  end

  test "there are no write routes", %{admin: admin, release: release, item: item} do
    key = mint(admin, :read_write)

    create = %{data: %{type: "release", attributes: %{name: "Nope"}}}
    assert {404, _} = req(:post, "/api/json/releases", key: key, body: create)

    patch = %{data: %{type: "release", id: release.id, attributes: %{name: "Changed"}}}
    assert {404, _} = req(:patch, "/api/json/releases/#{release.id}", key: key, body: patch)
    assert {404, _} = req(:delete, "/api/json/releases/#{release.id}", key: key)

    item_body = %{data: %{type: "release_item", attributes: %{content_type: "page"}}}
    assert {404, _} = req(:post, "/api/json/release-items", key: key, body: item_body)
    assert {404, _} = req(:delete, "/api/json/release-items/#{item.id}", key: key)

    assert CMS.get_release!(release.id, actor: admin).name == "Autumn launch"
    assert CMS.get_release_item!(item.id, actor: admin).status == :pending
  end

  test "the OpenAPI document still builds, describing the read routes and no writes",
       %{conn: conn} do
    conn = conn |> put_req_header("accept", "application/json") |> get("/api/json/open_api")
    paths = conn |> response(200) |> Jason.decode!() |> Map.fetch!("paths")

    for path <- ~w(/releases /releases/{id} /release-items /release-items/{id}) do
      methods = paths |> Enum.find_value(fn {p, ops} -> String.ends_with?(p, path) && ops end)
      assert methods, "#{path} missing from the OpenAPI document"
      assert Map.keys(methods) -- ["parameters"] == ["get"]
    end
  end
end
