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

  test "a non-kiln bearer value falls through to JWT handling (no 401 here)", %{conn: conn} do
    # A malformed/non-API-key bearer isn't treated as an invalid API key — it's
    # left for :load_from_bearer, which simply resolves no actor (anonymous).
    conn = conn |> with_key("not-a-kiln-key") |> get(~p"/api/locales")
    assert json_response(conn, 200)
    refute conn.assigns[:current_user]
  end

  defp future, do: DateTime.add(DateTime.utc_now(), 30, :day)
end
