defmodule KilnCMSWeb.UnknownScopeApiKeyTest do
  @moduledoc """
  An API key whose scope this release does not know never signs in (#2604).

  A newer release may add a scope, possibly narrower than read; after a
  rollback, or on an older node during a rolling deploy, this release meets
  keys minted with it. Such a key must authenticate as nothing, not fall
  through to its owner's reads. Every surface that accepts a key refuses it
  exactly as it refuses a revoked or unknown key: the `:api` pipeline
  (JSON:API, GraphQL), the `/mcp` pipeline, `Accounts.actor_from_api_key/1`
  (the bridge socket, key rotation) and the rotation endpoint.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.NewerReleaseRows

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "unknown-scope-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp days(n), do: DateTime.add(DateTime.utc_now(), n, :day)

  defp mint(owner, access) do
    attrs =
      if access == :draft_write,
        do: %{access: access, rotatable_until: days(90)},
        else: %{access: access}

    Accounts.mint_api_key!(owner.id, "reader", days(7), attrs, actor: user(:admin))
  end

  defp plaintext(key), do: Ash.Resource.get_metadata(key, :plaintext_api_key)

  # A live account's key, minted by a newer release with a scope this one
  # does not know. Returns the key and its secret.
  defp unknown_scope_key(owner \\ user(:admin), access \\ :read) do
    key = mint(owner, access)
    NewerReleaseRows.api_key_scope!(key.id)
    {key, plaintext(key)}
  end

  # A revoked key of a live account: the refusal to compare against.
  defp revoked_key(access \\ :read, owner \\ user(:admin)) do
    key = mint(owner, access)
    Accounts.revoke_api_key!(key, actor: user(:admin))
    plaintext(key)
  end

  # What a client can observe of a refusal.
  defp observed(conn) do
    {conn.status, conn.resp_body,
     for(
       header <- ["content-type", "www-authenticate", "cache-control", "vary"],
       do: {header, get_resp_header(conn, header)}
     )}
  end

  defp api_get(key) do
    build_conn()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("authorization", "Bearer #{key}")
    |> get("/api/json/posts")
  end

  defp locales(key) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{key}")
    |> get(~p"/api/locales")
  end

  defp gql(key) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{key}")
    |> post("/gql", Jason.encode!(%{query: "{ __typename }"}))
  end

  defp mcp(key) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{key}")
    |> post(~p"/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{}}))
  end

  defp rotate(key) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{key}")
    |> post("/api/keys/rotate")
  end

  defp key_ids(owner),
    do: owner.id |> Accounts.list_api_keys!(actor: user(:admin)) |> Enum.map(& &1.id)

  describe "a key whose scope this release does not know" do
    test "is refused on JSON:API like a revoked or unknown key" do
      {_key, secret} = unknown_scope_key()
      conn = api_get(secret)

      assert conn.status == 401
      refute conn.assigns[:current_user]
      assert observed(conn) == observed(api_get(revoked_key()))
      assert observed(conn) == observed(api_get("kiln_bogus_x"))
    end

    test "is refused on a delivery route, where the same key signed in a moment before" do
      owner = user(:admin)
      key = mint(owner, :read)
      secret = plaintext(key)

      assert locales(secret).status == 200

      NewerReleaseRows.api_key_scope!(key.id)
      conn = locales(secret)

      assert conn.status == 401
      assert observed(conn) == observed(locales(revoked_key()))
    end

    test "is refused on GraphQL like a revoked or unknown key" do
      {_key, secret} = unknown_scope_key()
      conn = gql(secret)

      assert conn.status == 401
      assert observed(conn) == observed(gql(revoked_key()))
      assert observed(conn) == observed(gql("kiln_bogus_x"))
    end

    test "is refused on /mcp like a revoked or unknown key" do
      {_key, secret} = unknown_scope_key(user(:admin), :read_write)
      conn = mcp(secret)

      assert conn.status == 401
      assert observed(conn) == observed(mcp(revoked_key(:read_write)))
      assert observed(conn) == observed(mcp("kiln_bogus_x"))
    end

    test "resolves to no actor off the request cycle (bridge socket, rotation)" do
      {_key, secret} = unknown_scope_key()
      assert :error = Accounts.actor_from_api_key(secret)
    end

    test "cannot rotate itself: refused like a revoked key, nothing minted, nothing revoked" do
      owner = user(:viewer)
      {key, secret} = unknown_scope_key(owner, :draft_write)

      conn = rotate(secret)

      assert conn.status == 401
      assert [%{"code" => "invalid_api_key"}] = Jason.decode!(conn.resp_body)["errors"]
      assert observed(conn) == observed(rotate(revoked_key(:draft_write, user(:viewer))))

      assert key_ids(owner) == [key.id]
      row = NewerReleaseRows.stored_row("api_keys", key.id)
      assert {row["revoked_at"], row["lineage_id"]} == {nil, nil}
    end
  end

  describe "a key with a known scope" do
    test "still signs in on every surface" do
      owner = user(:admin)
      key = owner |> mint(:read_write) |> plaintext()

      conn = api_get(key)
      assert conn.status == 200
      assert conn.assigns.current_user.id == owner.id

      assert gql(key).status == 200
      assert mcp(key).status == 200
      assert {:ok, %{id: id}} = Accounts.actor_from_api_key(key)
      assert id == owner.id
    end
  end
end
