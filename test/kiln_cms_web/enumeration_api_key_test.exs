defmodule KilnCMSWeb.EnumerationApiKeyTest do
  @moduledoc """
  API-key sign-in does not say what became of a key (#2255).

  A key is a random secret, not an address, so there is no account to find by
  guessing; what is guarded is the state of a key that *was* real. A key that
  never existed, one that has expired and one that was revoked are refused with
  the same status, challenge header and envelope, compared whole by
  `KilnCMS.EnumerationAssertions`. None of them says whose key it was.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.EnumerationAssertions

  alias KilnCMS.Accounts

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "enum-apikey-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp mint(expires_at) do
    key = Accounts.mint_api_key!(admin().id, "enum", expires_at, actor: admin())
    {key, Ash.Resource.get_metadata(key, :plaintext_api_key)}
  end

  defp request(plaintext) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{plaintext}")
    |> get(~p"/api/locales")
  end

  defp future, do: DateTime.add(DateTime.utc_now(), 30, :day)

  test "an expired key and a key that never existed are refused alike" do
    {_key, expired} = mint(DateTime.add(DateTime.utc_now(), -1, :minute))
    {_key, fresh} = mint(future())
    # Same shape and length as a real key, but not one: the last character moved.
    ghost = String.slice(fresh, 0..-2//1) <> if(String.ends_with?(fresh, "A"), do: "B", else: "A")

    seen =
      assert_indistinguishable(fn -> request(expired) end, fn -> request(ghost) end, [])

    assert seen.status == 401
  end

  test "a revoked key and a key that never existed are refused alike" do
    admin = admin()
    key = Accounts.mint_api_key!(admin().id, "enum", future(), actor: admin)
    plaintext = Ash.Resource.get_metadata(key, :plaintext_api_key)
    Accounts.revoke_api_key!(key, actor: admin)

    ghost =
      String.slice(plaintext, 0..-2//1) <>
        if(String.ends_with?(plaintext, "A"), do: "B", else: "A")

    assert_indistinguishable(fn -> request(plaintext) end, fn -> request(ghost) end, [])
  end
end
