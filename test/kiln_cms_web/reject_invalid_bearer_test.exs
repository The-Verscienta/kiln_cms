defmodule KilnCMSWeb.RejectInvalidBearerTest do
  @moduledoc """
  `KILN_API_REJECT_INVALID_BEARER` (#2161): with the flag on (the default
  since the release after it shipped, ADR 0012), an `Authorization: Bearer`
  value that verifies as nothing is a `401` in the standard error envelope on
  `/api/json` and `/gql`; set explicitly to `false` it is served as anonymous,
  the escape hatch kept for one more release.
  """
  # async: false — flips process-global application env.
  use KilnCMSWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Accounts

  @password "password123456"
  @accept "application/vnd.api+json"

  setup do
    previous = Application.get_env(:kiln_cms, KilnCMSWeb.Plugs.ApiKeyAuth)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, KilnCMSWeb.Plugs.ApiKeyAuth, previous),
        else: Application.delete_env(:kiln_cms, KilnCMSWeb.Plugs.ApiKeyAuth)
    end)

    :ok
  end

  defp flag(value),
    do: Application.put_env(:kiln_cms, KilnCMSWeb.Plugs.ApiKeyAuth, reject_invalid_bearer: value)

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "bearer-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp jwt(user) do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => user.email, "password" => @password},
        []
      )

    signed_in.__metadata__.token
  end

  defp api_get(authorization) do
    conn = put_req_header(build_conn(), "accept", @accept)

    conn =
      if authorization, do: put_req_header(conn, "authorization", authorization), else: conn

    get(conn, "/api/json/posts")
  end

  defp gql(authorization) do
    conn = put_req_header(build_conn(), "content-type", "application/json")

    conn =
      if authorization, do: put_req_header(conn, "authorization", authorization), else: conn

    post(conn, "/gql", Jason.encode!(%{query: "{ __typename }"}))
  end

  defp assert_envelope(conn) do
    assert conn.status == 401

    assert [%{"status" => "401", "code" => "invalid_token", "detail" => _}] =
             Jason.decode!(conn.resp_body)["errors"]

    assert [~s(Bearer error="invalid_token")] = get_resp_header(conn, "www-authenticate")
  end

  describe "flag on" do
    setup do: flag(true)

    test "a garbled bearer is a 401 envelope on JSON:API and GraphQL" do
      assert_envelope(api_get("Bearer not.a.jwt"))
      assert_envelope(gql("Bearer not.a.jwt"))
      assert_envelope(api_get("Bearer "))
    end

    test "a JWT signed in with a different secret is a 401" do
      forged =
        Phoenix.Token.sign(KilnCMSWeb.Endpoint, "something else", %{"sub" => "user?id=1"})

      assert_envelope(api_get("Bearer " <> forged))
    end

    test "no Authorization header stays anonymous" do
      assert api_get(nil).status == 200
      assert gql(nil).status == 200
    end

    test "another scheme is not a bearer and stays anonymous" do
      assert api_get("Basic dXNlcjpwYXNz").status == 200
    end

    test "a valid JWT and a valid API key are untouched" do
      editor = user(:editor)
      assert api_get("Bearer " <> jwt(editor)).status == 200
      assert gql("Bearer " <> jwt(editor)).status == 200

      key =
        editor.id
        |> Accounts.mint_api_key!(
          "k",
          DateTime.add(DateTime.utc_now(), 7, :day),
          %{access: :read},
          actor: user(:admin)
        )
        |> Ash.Resource.get_metadata(:plaintext_api_key)

      assert api_get("Bearer " <> key).status == 200
    end

    # `KilnCMS.Accounts.User` has no suspended, disabled, locked or
    # pending-approval state, and `get_by_subject` filters on the subject alone
    # (no `confirmed_at` or role check), so account state cannot by itself stop
    # a live JWT resolving. The ways one stops are all token rows: revoked
    # (password change, "sign out everywhere", erasure), held for a second
    # factor (below), or the user row being gone.
    test "a first-factor JWT held while its account owes a second factor is a 401" do
      {user, _secret} = KilnCMS.TwoFactorFixtures.enabled_user(role: :editor)
      {_user, token} = KilnCMS.TwoFactorFixtures.with_first_factor_token(user)
      {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)

      # Served until it is parked, so the 401 below is the hold's doing.
      assert api_get("Bearer " <> token).status == 200

      {1, _} =
        KilnCMS.Repo.update_all(from(t in "tokens", where: t.jti == ^jti),
          set: [purpose: KilnCMS.Accounts.Token.second_factor_hold_purpose()]
        )

      assert_envelope(api_get("Bearer " <> token))
      assert_envelope(gql("Bearer " <> token))
    end

    # `:api_spec` runs `ApiKeyAuth` without `:load_from_bearer`, so a valid
    # JWT has no actor there; the rejection must not read that as a bad token.
    test "a valid JWT on the GraphQL SDL route (no JWT loader) is not a 401" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> jwt(user(:editor)))
        |> get("/api/graphql/schema.graphql")

      refute conn.status == 401
    end

    test "a bad kiln_ key was already a 401 and still is" do
      assert api_get("Bearer kiln_nonsense").status == 401
      assert gql("Bearer kiln_nonsense").status == 401
    end
  end

  describe "default (unset)" do
    test "unset config is on: an unverifiable bearer is a 401" do
      Application.delete_env(:kiln_cms, KilnCMSWeb.Plugs.ApiKeyAuth)
      assert KilnCMSWeb.Plugs.ApiKeyAuth.reject_invalid_bearer?()
      assert_envelope(api_get("Bearer not.a.jwt"))
      assert_envelope(gql("Bearer not.a.jwt"))
    end

    test "unset config still serves a request with no Authorization header" do
      Application.delete_env(:kiln_cms, KilnCMSWeb.Plugs.ApiKeyAuth)
      assert api_get(nil).status == 200
    end
  end

  describe "flag explicitly off (the escape hatch)" do
    setup do: flag(false)

    test "an unverifiable bearer is served as anonymous" do
      refute KilnCMSWeb.Plugs.ApiKeyAuth.reject_invalid_bearer?()
      assert api_get("Bearer not.a.jwt").status == 200
      assert gql("Bearer not.a.jwt").status == 200
    end

    # Served as anonymous, but it carried a credential: never publicly cached.
    test "the anonymous fallback is still private, no-store" do
      conn = api_get("Bearer not.a.jwt")
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "surrogate-key") == []
    end
  end

  describe "telemetry (ADR 0017)" do
    @event [:kiln_cms, :api, :invalid_bearer]

    setup do
      id = "invalid-bearer-#{System.unique_integer([:positive])}"
      test = self()
      :telemetry.attach(id, @event, fn e, m, meta, _ -> send(test, {e, m, meta}) end, nil)
      on_exit(fn -> :telemetry.detach(id) end)
    end

    defp expired_jwt do
      {:ok, token, _} =
        AshAuthentication.Jwt.token_for_user(user(:editor), %{}, token_lifetime: {-1, :minutes})

      token
    end

    test "says reason, surface, read-ness and enforcement" do
      flag(true)

      api_get("Bearer garbage")

      assert_receive {@event, %{count: 1},
                      %{reason: :malformed, surface: :json_api, read?: true, enforced: true}}

      api_get("Bearer " <> expired_jwt())
      assert_receive {@event, _, %{reason: :expired}}

      gql("Bearer garbage")
      assert_receive {@event, _, %{surface: :graphql, read?: true}}
    end

    test "fires with the escape hatch on, marked not enforced" do
      flag(false)
      assert api_get("Bearer garbage").status == 200
      assert_receive {@event, _, %{enforced: false}}
    end

    test "silent for anonymous, valid and other-scheme requests" do
      api_get(nil)
      api_get("Bearer " <> jwt(user(:editor)))
      api_get("Basic dXNlcjpwYXNz")
      refute_receive {@event, _, _}
    end
  end
end
