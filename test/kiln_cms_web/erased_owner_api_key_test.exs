defmodule KilnCMSWeb.ErasedOwnerApiKeyTest do
  @moduledoc """
  An erased account's API key never signs in, even one erasure left
  unrevoked (an account erased before erasure revoked keys). Every surface
  that accepts a key refuses it exactly as it refuses a revoked or unknown
  key: the `:api` pipeline (JSON:API, GraphQL), the `/mcp` pipeline, and
  `Accounts.actor_from_api_key/1` (the bridge socket, key rotation).
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "erased-key-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint(owner, access) do
    Accounts.mint_api_key!(
      owner.id,
      "reader",
      DateTime.add(DateTime.utc_now(), 30, :day),
      %{access: access},
      actor: user(:admin)
    )
  end

  defp plaintext(key), do: Ash.Resource.get_metadata(key, :plaintext_api_key)

  # Tombstoned as erasure does, but with the key left unrevoked: the state an
  # account erased before erasure revoked keys is still in.
  defp erase_leaving_keys(owner) do
    Ash.Seed.update!(owner, %{
      email: "anonymized-#{owner.id}@deleted.invalid",
      name: nil,
      anonymized_at: DateTime.utc_now()
    })
  end

  # A key whose owner was erased while the key stayed live.
  defp erased_owner_key(access \\ :read) do
    owner = user(:admin)
    key = mint(owner, access)
    erase_leaving_keys(owner)
    plaintext(key)
  end

  # A revoked key of a live account: the refusal to compare against.
  defp revoked_key(access \\ :read) do
    key = mint(user(:admin), access)
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

  describe "a key whose owner was erased" do
    test "is refused on JSON:API like a revoked or unknown key" do
      conn = api_get(erased_owner_key())

      assert conn.status == 401
      refute conn.assigns[:current_user]
      assert observed(conn) == observed(api_get(revoked_key()))
      assert observed(conn) == observed(api_get("kiln_bogus_x"))
    end

    test "is refused on GraphQL like a revoked or unknown key" do
      conn = gql(erased_owner_key())

      assert conn.status == 401
      assert observed(conn) == observed(gql(revoked_key()))
      assert observed(conn) == observed(gql("kiln_bogus_x"))
    end

    test "is refused on /mcp like a revoked or unknown key" do
      conn = mcp(erased_owner_key(:read_write))

      assert conn.status == 401
      assert observed(conn) == observed(mcp(revoked_key(:read_write)))
      assert observed(conn) == observed(mcp("kiln_bogus_x"))
    end

    test "resolves to no actor off the request cycle (bridge socket, rotation)" do
      assert :error = Accounts.actor_from_api_key(erased_owner_key())
    end

    test "cannot rotate itself, refused like a revoked or unknown key" do
      conn = rotate(erased_owner_key())

      assert conn.status == 401
      assert observed(conn) == observed(rotate(revoked_key()))
      assert observed(conn) == observed(rotate("kiln_bogus_x"))
    end
  end

  describe "a live account's key" do
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
