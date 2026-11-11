defmodule KilnCMSWeb.Plugs.ApiKeyAuthTest do
  @moduledoc "API-key authentication over the headless :api pipeline."
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "apikey-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp mint(owner, opts \\ []) do
    admin = admin()
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 30, :day))
    key = Accounts.mint_api_key!(owner.id, "reader", expires_at, actor: admin)
    Ash.Resource.get_metadata(key, :plaintext_api_key)
  end

  defp with_key(conn, plaintext), do: put_req_header(conn, "authorization", "Bearer #{plaintext}")

  test "a valid API key authenticates as its owning user", %{conn: conn} do
    owner = admin()
    plaintext = mint(owner)

    conn = conn |> with_key(plaintext) |> get(~p"/api/locales")

    assert json_response(conn, 200)
    assert conn.assigns.current_user.id == owner.id
  end

  test "a bogus API key is rejected with 401", %{conn: conn} do
    conn = conn |> with_key("kiln_deadbeef_00") |> get(~p"/api/locales")
    assert conn.status == 401
    assert conn.halted
  end

  test "an expired key is rejected", %{conn: conn} do
    plaintext = mint(admin(), expires_at: DateTime.add(DateTime.utc_now(), -1, :minute))
    conn = conn |> with_key(plaintext) |> get(~p"/api/locales")
    assert conn.status == 401
  end

  test "a revoked key is rejected", %{conn: conn} do
    owner = admin()
    admin = admin()
    key = Accounts.mint_api_key!(owner.id, "reader", future(), actor: admin)
    plaintext = Ash.Resource.get_metadata(key, :plaintext_api_key)
    Accounts.revoke_api_key!(key, actor: admin)

    conn = conn |> with_key(plaintext) |> get(~p"/api/locales")
    assert conn.status == 401
  end

  test "a non-kiln bearer value falls through to JWT handling", %{conn: conn} do
    # A malformed/non-API-key bearer isn't treated as an invalid API key — it's
    # left for :load_from_bearer, which resolves no actor. Since #2161's default
    # flip that is an `invalid_token` 401 (a bad JWT), not an API-key rejection;
    # `KilnCMSWeb.RejectInvalidBearerTest` covers the opt-out.
    conn = conn |> with_key("not-a-kiln-key") |> get(~p"/api/locales")
    assert [%{"code" => "invalid_token"}] = json_response(conn, 401)["errors"]
    refute conn.assigns[:current_user]
  end

  describe "where the key sits in the header (#2633)" do
    defp with_authorization(conn, values),
      do: %{conn | req_headers: Enum.map(values, &{"authorization", &1}) ++ conn.req_headers}

    test "a key under a lower-case or mixed-case scheme authenticates", %{conn: conn} do
      owner = admin()
      plaintext = mint(owner)

      for scheme <- ["bearer", "BEARER", "bEaReR"] do
        conn = conn |> with_authorization(["#{scheme} #{plaintext}"]) |> get(~p"/api/locales")

        assert json_response(conn, 200)
        assert conn.assigns.current_user.id == owner.id
      end
    end

    test "a key that is not the first authorization value authenticates", %{conn: conn} do
      owner = admin()
      plaintext = mint(owner)
      values = ["Basic dXNlcjpwYXNz", "Bearer #{plaintext}"]

      conn = conn |> with_authorization(values) |> get(~p"/api/locales")

      assert json_response(conn, 200)
      assert conn.assigns.current_user.id == owner.id
      # The normalized header the key plug saw is not left behind.
      assert get_req_header(conn, "authorization") == values
    end

    test "extra whitespace around the scheme and key is tolerated", %{conn: conn} do
      owner = admin()
      plaintext = mint(owner)

      conn = conn |> with_authorization(["  Bearer   #{plaintext}  "]) |> get(~p"/api/locales")

      assert conn.assigns.current_user.id == owner.id
    end

    test "the first key decides: an invalid one is a 401 even beside a valid one", %{conn: conn} do
      plaintext = mint(admin())

      conn =
        conn
        |> with_authorization(["Bearer kiln_deadbeef_00", "Bearer #{plaintext}"])
        |> get(~p"/api/locales")

      assert conn.status == 401
      refute conn.assigns[:current_user]
    end

    test "a later key is ignored once the first has authenticated", %{conn: conn} do
      owner = admin()
      plaintext = mint(owner)

      conn =
        conn
        |> with_authorization(["bearer #{plaintext}", "Bearer kiln_deadbeef_00"])
        |> get(~p"/api/locales")

      assert json_response(conn, 200)
      assert conn.assigns.current_user.id == owner.id
    end

    test "a key wins over a valid JWT sent alongside it", %{conn: conn} do
      {:ok, jwt, _} = AshAuthentication.Jwt.token_for_user(admin())
      owner = admin()
      plaintext = mint(owner)

      conn =
        conn
        |> with_authorization(["Bearer #{jwt}", "Bearer #{plaintext}"])
        |> get(~p"/api/locales")

      assert json_response(conn, 200)
      assert conn.assigns.current_user.id == owner.id
    end

    test "an invalid key under a lower-case scheme is an invalid key, not a stale JWT",
         %{conn: conn} do
      conn = conn |> with_authorization(["bearer kiln_deadbeef_00"]) |> get(~p"/api/locales")

      assert conn.status == 401
      assert conn.halted
      refute get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")]
    end

    test "a stale bearer after a non-bearer value is still a 401 (#2161)", %{conn: conn} do
      conn =
        conn
        |> with_authorization(["Basic dXNlcjpwYXNz", "bearer garbage"])
        |> get(~p"/api/locales")

      assert [%{"code" => "invalid_token"}] = json_response(conn, 401)["errors"]
      refute conn.assigns[:current_user]
    end
  end

  defp future, do: DateTime.add(DateTime.utc_now(), 30, :day)
end
