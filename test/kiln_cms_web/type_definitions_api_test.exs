defmodule KilnCMSWeb.TypeDefinitionsApiTest do
  @moduledoc """
  `/api/json/type-definitions` — the read-only discovery surface a headless
  writer uses to find the `type_definition_id` that `POST /api/json/entries`
  requires (the JSON:API twin of MCP's `read_type_definitions`).

  Same `:read` and policies as the MCP tool: editor-or-above of the request's
  org reads, a viewer or anonymous caller gets nothing, archived types never
  list, and the host's org bounds what any credential can see.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @accept "application/vnd.api+json"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "tdapi-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint(owner, access) do
    key =
      Accounts.mint_api_key!(
        owner.id,
        "type-definitions-api",
        DateTime.add(DateTime.utc_now(), 30, :day),
        %{access: access},
        actor: user(:admin)
      )

    Ash.Resource.get_metadata(key, :plaintext_api_key)
  end

  defp define_type!(actor, opts \\ []) do
    CMS.create_type_definition!(
      %{name: "td#{System.unique_integer([:positive])}", label: "Discoverable"},
      actor: actor,
      tenant: opts[:tenant]
    )
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

  setup do
    admin = user(:admin)
    %{admin: admin, definition: define_type!(admin)}
  end

  describe "who can read" do
    test "an editor's read-only key lists the org's types with their public fields",
         %{definition: definition} do
      key = mint(user(:editor), :read)

      {200, %{"data" => data}} = req(:get, "/api/json/type-definitions", key: key)
      row = Enum.find(data, &(&1["id"] == definition.id))

      assert row["type"] == "type_definition"
      assert row["attributes"]["name"] == definition.name
      assert row["attributes"]["label"] == "Discoverable"
      assert row["attributes"]["path_segment"] == definition.path_segment
      refute Map.has_key?(row["attributes"], "org_id")
    end

    test "an anonymous caller gets an empty list and a 404 on the record", %{definition: d} do
      assert {200, %{"data" => []}} = req(:get, "/api/json/type-definitions")
      assert {404, _} = req(:get, "/api/json/type-definitions/#{d.id}")
      assert {404, _} = req(:get, "/api/json/type-definitions/by-name/#{d.name}")
    end

    test "a viewer's key — even a read-write one — sees nothing", %{definition: d} do
      key = mint(user(:viewer), :read_write)

      assert {200, %{"data" => []}} = req(:get, "/api/json/type-definitions", key: key)
      assert {404, _} = req(:get, "/api/json/type-definitions/by-name/#{d.name}", key: key)
    end
  end

  describe "resolving a type" do
    test "by-name answers the id in one call; a miss is a 404", %{definition: d} do
      key = mint(user(:editor), :read)

      assert {200, %{"data" => %{"id" => id, "attributes" => %{"name" => name}}}} =
               req(:get, "/api/json/type-definitions/by-name/#{d.name}", key: key)

      assert id == d.id
      assert name == d.name
      assert {404, _} = req(:get, "/api/json/type-definitions/by-name/nosuchtype", key: key)
    end

    test "filter[name] on the index narrows to that type, and page[limit] is honoured",
         %{admin: admin, definition: d} do
      _other = define_type!(admin)
      key = mint(user(:editor), :read)

      assert ids(req(:get, "/api/json/type-definitions?filter[name]=#{d.name}", key: key)) ==
               [d.id]

      assert {200, %{"data" => [_one]}} =
               req(:get, "/api/json/type-definitions?page[limit]=1", key: key)
    end

    test "include=field_definitions carries the custom-field schema",
         %{admin: admin, definition: d} do
      field =
        CMS.create_field_definition!(
          %{type_definition_id: d.id, name: "torque", label: "Torque", field_type: :integer},
          actor: admin
        )

      key = mint(user(:editor), :read)

      {200, %{"data" => data, "included" => included}} =
        req(:get, "/api/json/type-definitions/#{d.id}?include=field_definitions", key: key)

      assert %{"relationships" => %{"field_definitions" => %{"data" => [ref]}}} = data
      assert ref == %{"type" => "field_definition", "id" => field.id}

      assert [%{"type" => "field_definition", "attributes" => attrs}] = included
      assert attrs["name"] == "torque"
      assert attrs["field_type"] == "integer"
      refute Map.has_key?(attrs, "org_id")
    end
  end

  describe "what never lists" do
    test "an archived type is gone from the index and by-name", %{admin: admin} do
      archived = define_type!(admin)
      :ok = Ash.destroy!(archived, actor: admin)
      key = mint(user(:editor), :read)

      refute archived.id in ids(req(:get, "/api/json/type-definitions", key: key))

      assert {404, _} =
               req(:get, "/api/json/type-definitions/by-name/#{archived.name}", key: key)
    end

    test "another org's types are invisible from this org's host, whatever the key",
         %{admin: admin, definition: home} do
      other_org = KilnCMS.OrgFixtures.org("tdapi")
      foreign = define_type!(admin, tenant: other_org)

      # A global admin key: the tier check passes everywhere, so only the
      # host's tenant keeps the other site's registry out.
      admin_key = mint(admin, :read)
      listed = ids(req(:get, "/api/json/type-definitions", key: admin_key))
      assert home.id in listed
      refute foreign.id in listed

      assert {404, _} =
               req(:get, "/api/json/type-definitions/by-name/#{foreign.name}", key: admin_key)

      # The same key on the other org's host sees that org's type — and not ours.
      there = ids(req(:get, "/api/json/type-definitions", key: admin_key, org: other_org))
      assert foreign.id in there
      refute home.id in there

      # A default-org editor has no tier on the other org at all.
      editor_key = mint(user(:editor), :read)

      assert {200, %{"data" => []}} =
               req(:get, "/api/json/type-definitions", key: editor_key, org: other_org)
    end

    test "there are no write routes", %{admin: admin, definition: d} do
      key = mint(admin, :read_write)
      body = %{data: %{type: "type_definition", attributes: %{name: "nope", label: "Nope"}}}

      assert {404, _} = req(:post, "/api/json/type-definitions", key: key, body: body)

      patch = %{data: %{type: "type_definition", id: d.id, attributes: %{label: "Changed"}}}
      assert {404, _} = req(:patch, "/api/json/type-definitions/#{d.id}", key: key, body: patch)
      assert {404, _} = req(:delete, "/api/json/type-definitions/#{d.id}", key: key)

      assert CMS.get_type_definition!(d.id, actor: admin).label == "Discoverable"
    end
  end

  # The flow docs/json-api.md walks through: name → id → create an entry.
  test "a headless writer resolves a type by name, then creates an entry under it",
       %{definition: d} do
    key = mint(user(:editor), :read_write)

    {200, %{"data" => %{"id" => type_id}}} =
      req(:get, "/api/json/type-definitions/by-name/#{d.name}", key: key)

    body = %{
      data: %{
        type: "entry",
        attributes: %{
          title: "Written against a discovered type",
          slug: "td-#{System.unique_integer([:positive])}",
          type_definition_id: type_id
        }
      }
    }

    assert {201, %{"data" => %{"id" => entry_id}}} =
             req(:post, "/api/json/entries", key: key, body: body)

    assert {200, %{"data" => %{"attributes" => %{"type_name" => type_name}}}} =
             req(:get, "/api/json/entries/#{entry_id}?fields[entry]=type_name", key: key)

    assert type_name == d.name
  end
end
