defmodule KilnCMSWeb.ApiAuthControllerTest do
  @moduledoc """
  Headless sign-in (`POST /api/auth/sign_in`) — exchanges credentials for a
  bearer token usable against the JSON:API / GraphQL surfaces (issue #37), and
  the second step a two-factor account owes before it gets one (#726).
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.RecoveryCodes
  alias KilnCMS.Accounts.Totp
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMSWeb.BearerAuth
  alias KilnCMSWeb.Endpoint

  @password "password123456"
  @pending_salt "api two-factor pending"

  defp unique, do: System.unique_integer([:positive])

  # Ids of the draft posts a bearer token can see. Anonymous callers see none —
  # the read policy hides unpublished content — so this is a direct read of
  # "who does the server think is calling".
  defp draft_ids(token) do
    conn =
      build_conn()
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/json/posts?filter[state]=draft")

    case conn.status do
      200 -> conn.resp_body |> Jason.decode!() |> Map.fetch!("data") |> Enum.map(& &1["id"])
      _refused -> []
    end
  end

  defp seed_user(role, extra \\ %{}) do
    email = "#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        extra
      )
    )
  end

  defp seed_totp_user(role \\ :editor) do
    secret = :crypto.strong_rand_bytes(20)

    user =
      seed_user(role, %{totp_secret: secret, totp_confirmed_at: DateTime.utc_now()})

    {user, secret}
  end

  defp post_sign_in(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/auth/sign_in", body)
  end

  defp seed_org do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: "Org #{unique()}",
      slug: "org-#{unique()}"
    })
  end

  defp membership(user, org, tier) do
    Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  # Sign in over `org`'s own host, so `SetTenant` resolves that org and the
  # response's per-org tier is the one for it.
  defp sign_in_on(org, user) do
    host = "#{org.slug}.#{KilnCMSWeb.Tenant.base_host()}"

    %{build_conn() | host: host}
    |> post_sign_in(%{email: to_string(user.email), password: @password})
  end

  defp post_verify(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/auth/sign_in/verify", body)
  end

  # The first leg for a 2FA account: correct password, back comes a pending
  # token and no JWT.
  defp begin_two_factor(conn, user) do
    conn = post_sign_in(conn, %{email: to_string(user.email), password: @password})
    %{"pending_token" => pending} = json_response(conn, 200)
    pending
  end

  defp current_code(secret), do: Totp.code_at(secret, System.system_time(:second))

  describe "single-factor accounts" do
    test "valid credentials return a usable bearer token + user", %{conn: conn} do
      user = seed_user(:editor)

      conn = post_sign_in(conn, %{email: to_string(user.email), password: @password})

      assert %{"token" => token, "user" => returned} = json_response(conn, 201)
      assert returned["id"] == user.id
      assert returned["email"] == to_string(user.email)
      assert returned["role"] == "editor"

      # The token authenticates as the signed-in user.
      assert {:ok, authed} = BearerAuth.user_from_token(token)
      assert authed.id == user.id
    end

    # `role` is the EFFECTIVE tier on the request's org (#627), not the global
    # one — so the same account, same credentials, is described differently
    # depending on the host it signs in against.
    test "role is the per-org effective tier, keyed on the request host", %{conn: _conn} do
      user = seed_user(:viewer)
      org_a = seed_org()
      org_b = seed_org()
      membership(user, org_a, :admin)
      membership(user, org_b, :editor)

      # Against org A's host, an admin…
      resp_a = sign_in_on(org_a, user) |> json_response(201)
      assert resp_a["user"]["role"] == "admin"

      # …against org B's host, an editor — not the admin they are on A.
      resp_b = sign_in_on(org_b, user) |> json_response(201)
      assert resp_b["user"]["role"] == "editor"
    end

    test "role is `none` on a host where the account has no tier", %{conn: _conn} do
      user = seed_user(:viewer)
      other_org = seed_org()

      assert sign_in_on(other_org, user) |> json_response(201) |> get_in(["user", "role"]) ==
               "none"
    end

    test "wrong password is a generic 401", %{conn: conn} do
      user = seed_user(:admin)

      conn = post_sign_in(conn, %{email: to_string(user.email), password: "wrong-password"})

      assert %{"errors" => [%{"detail" => detail, "code" => code}]} = json_response(conn, 401)
      assert detail == "Invalid email or password"
      assert code == "invalid_credentials"
    end

    test "unknown email is the same generic 401 (no user enumeration)", %{conn: conn} do
      conn = post_sign_in(conn, %{email: "nobody@example.com", password: @password})

      assert %{"errors" => [%{"detail" => "Invalid email or password"}]} =
               json_response(conn, 401)
    end

    test "missing fields are a 422", %{conn: conn} do
      conn = post_sign_in(conn, %{email: "someone@example.com"})

      assert %{"errors" => [%{"detail" => detail}]} = json_response(conn, 422)
      assert detail =~ "required"
    end
  end

  describe "two-factor accounts: the password alone (#726)" do
    test "does not issue a token — 200 with a pending token, not 201", %{conn: conn} do
      {user, _secret} = seed_totp_user()

      conn = post_sign_in(conn, %{email: to_string(user.email), password: @password})

      body = json_response(conn, 200)
      assert body["two_factor_required"] == true
      assert is_binary(body["pending_token"])
      assert body["expires_in"] == 300

      # The whole point: no credential came back.
      refute Map.has_key?(body, "token")
      refute Map.has_key?(body, "user")
    end

    test "a wrong password on a 2FA account is the same generic 401", %{conn: conn} do
      {user, _secret} = seed_totp_user()

      conn = post_sign_in(conn, %{email: to_string(user.email), password: "wrong-password"})

      # The 200/201 split discloses that an account has a second factor, but
      # only to a caller who already has the password. Hoisting totp_enabled?/1
      # above the sign-in action — an obvious-looking optimisation, since it
      # skips a bcrypt — would turn this endpoint into a pre-auth enumeration
      # oracle for which accounts have 2FA. Nothing else pins that ordering.
      body = json_response(conn, 401)
      assert [%{"code" => "invalid_credentials"}] = body["errors"]
      refute body["two_factor_required"]
    end

    test "the pending token does not authenticate the JSON:API, but the redeemed one does",
         %{conn: conn} do
      {user, secret} = seed_totp_user(:admin)
      draft = CMS.create_post!(%{title: "Draft", slug: "pending-#{unique()}"}, actor: user)

      pending = begin_two_factor(conn, user)

      # Against the real `:api` pipeline, not `BearerAuth` — that helper serves
      # the sockets, while `/api/json/**` authenticates through
      # AshAuthentication's `load_from_bearer`. This is #726's claim stated
      # where it has to hold: an admin's password alone buys no admin reads.
      refute draft.id in draft_ids(pending)

      # The other half, which is what makes the line above mean something: the
      # token from the completed exchange DOES see it. Without this the first
      # assertion would still pass against an endpoint that authenticates nobody.
      %{"token" => jwt} =
        conn
        |> post_verify(%{pending_token: pending, code: current_code(secret)})
        |> json_response(201)

      assert draft.id in draft_ids(jwt)
    end

    # The verify leg shares `issue_token/2`, so it must carry the same per-org
    # tier (#627) — and its host, not the sign-in host, is what decides it.
    test "the completed 2FA exchange returns the per-org effective tier" do
      {user, secret} = seed_totp_user(:viewer)
      org_b = seed_org()
      membership(user, org_b, :editor)

      host = "#{org_b.slug}.#{KilnCMSWeb.Tenant.base_host()}"
      pending = begin_two_factor(%{build_conn() | host: host}, user)

      resp =
        %{build_conn() | host: host}
        |> post_verify(%{pending_token: pending, code: current_code(secret)})
        |> json_response(201)

      assert resp["user"]["role"] == "editor"
    end

    test "the pending token is encrypted, so the first-factor JWT is not readable from it",
         %{conn: conn} do
      {user, _secret} = seed_totp_user()

      conn = post_sign_in(conn, %{email: to_string(user.email), password: @password})
      %{"pending_token" => pending} = json_response(conn, 200)

      # If this ever becomes `Phoenix.Token.sign/4` — as the browser flow's
      # session-held blob legitimately is — the JWT it carries ships to the
      # client in a decodable payload and #726 is reopened wearing a fix.
      assert {:error, _} = Phoenix.Token.verify(Endpoint, @pending_salt, pending, max_age: 300)

      assert {:ok, %{"user_id" => _, "token" => jwt}} =
               Phoenix.Token.decrypt(Endpoint, @pending_salt, pending)

      # And the JWT is nowhere in what went over the wire, encrypted or not.
      refute conn.resp_body =~ jwt
    end

    test "a browser pending blob is not accepted here, salt separation included" do
      {user, secret} = seed_totp_user()

      payload = %{"user_id" => user.id, "token" => "stub.jwt.token"}

      # Two blobs, because they fail for two different reasons and only one of
      # them is the reason that matters. The *signed* one is refused whatever the
      # salt — a signed token can never be decrypted — so on its own it pins
      # nothing. The *encrypted* one under the browser's salt is refused only
      # because the salts differ, which is the separation the moduledoc and the
      # threat model both call load-bearing.
      signed = Phoenix.Token.sign(Endpoint, "two-factor pending", payload)
      encrypted_wrong_salt = Phoenix.Token.encrypt(Endpoint, "two-factor pending", payload)

      for blob <- [signed, encrypted_wrong_salt] do
        refused = post_verify(build_conn(), %{pending_token: blob, code: current_code(secret)})
        assert %{"errors" => [%{"code" => "pending_expired"}]} = json_response(refused, 401)
      end
    end
  end

  describe "two-factor accounts: the verify step (#726)" do
    test "a valid TOTP code returns the bearer token", %{conn: conn} do
      {user, secret} = seed_totp_user(:admin)

      pending = begin_two_factor(conn, user)
      conn = post_verify(conn, %{pending_token: pending, code: current_code(secret)})

      assert %{"token" => token, "user" => returned} = json_response(conn, 201)
      assert returned["id"] == user.id
      assert returned["role"] == "admin"

      assert {:ok, authed} = BearerAuth.user_from_token(token)
      assert authed.id == user.id
    end

    test "a code with the spacing an authenticator app displays is accepted", %{conn: conn} do
      {user, secret} = seed_totp_user()

      pending = begin_two_factor(conn, user)
      spaced = String.replace(current_code(secret), ~r/(\d{3})(\d{3})/, "\\1 \\2")

      conn = post_verify(conn, %{pending_token: pending, code: spaced})

      assert %{"token" => _} = json_response(conn, 201)
    end

    test "a recovery code works and is burned", %{conn: conn} do
      {user, _secret} = seed_totp_user()
      codes = RecoveryCodes.generate()

      user =
        Ash.Seed.update!(user, %{totp_recovery_hashes: Enum.map(codes, &RecoveryCodes.hash/1)})

      [code | _] = codes

      pending = begin_two_factor(conn, user)
      conn = post_verify(conn, %{pending_token: pending, code: code})

      assert %{"token" => _} = json_response(conn, 201)

      reloaded = Accounts.get_user!(user.id, authorize?: false)
      assert length(reloaded.totp_recovery_hashes) == length(codes) - 1
      refute RecoveryCodes.hash(code) in reloaded.totp_recovery_hashes
    end

    test "a wrong code is a 401 that says so", %{conn: conn} do
      {user, _secret} = seed_totp_user()

      pending = begin_two_factor(conn, user)
      conn = post_verify(conn, %{pending_token: pending, code: "000000"})

      assert %{"errors" => [%{"code" => "invalid_code"}]} = json_response(conn, 401)
    end

    test "a tampered pending token is refused", %{conn: conn} do
      {user, secret} = seed_totp_user()

      pending = begin_two_factor(conn, user)
      tampered = "x" <> pending

      conn = post_verify(conn, %{pending_token: tampered, code: current_code(secret)})

      assert %{"errors" => [%{"code" => "pending_expired"}]} = json_response(conn, 401)
    end

    test "an expired pending token is refused", %{conn: conn} do
      {user, secret} = seed_totp_user()

      # Minted 301 seconds ago — one past the lifetime the first leg advertises.
      stale =
        Phoenix.Token.encrypt(
          Endpoint,
          @pending_salt,
          %{"user_id" => user.id, "token" => "stub.jwt.token"},
          signed_at: System.system_time(:second) - 301
        )

      conn = post_verify(conn, %{pending_token: stale, code: current_code(secret)})

      assert %{"errors" => [%{"code" => "pending_expired"}]} = json_response(conn, 401)
    end

    test "a pending token for an account that has since disabled 2FA is refused", %{conn: conn} do
      {user, secret} = seed_totp_user()

      pending = begin_two_factor(conn, user)
      Ash.Seed.update!(user, %{totp_secret: nil, totp_confirmed_at: nil})

      conn = post_verify(conn, %{pending_token: pending, code: current_code(secret)})

      assert %{"errors" => [%{"code" => "pending_expired"}]} = json_response(conn, 401)
    end

    test "a redeemed pending token cannot be replayed", %{conn: conn} do
      {user, secret} = seed_totp_user()

      pending = begin_two_factor(conn, user)
      code = current_code(secret)

      assert %{"token" => _} =
               build_conn()
               |> post_verify(%{pending_token: pending, code: code})
               |> json_response(201)

      # The same body again, well inside both the code's window and the blob's
      # five minutes. A captured verify request is the one most likely to be
      # sitting in a log, and the browser flow burns its equivalent by deleting
      # the session key.
      replay = post_verify(build_conn(), %{pending_token: pending, code: code})
      assert %{"errors" => [%{"code" => "pending_expired"}]} = json_response(replay, 401)
    end

    test "a wrong code does NOT burn the pending token", %{conn: conn} do
      {user, secret} = seed_totp_user()

      pending = begin_two_factor(conn, user)

      assert %{"errors" => [%{"code" => "invalid_code"}]} =
               build_conn()
               |> post_verify(%{pending_token: pending, code: "000000"})
               |> json_response(401)

      # A mistyped code is not a failed authentication, so the client retries the
      # code rather than the password — same as the browser prompt.
      assert %{"token" => _} =
               build_conn()
               |> post_verify(%{pending_token: pending, code: current_code(secret)})
               |> json_response(201)
    end

    test "recovery codes still work when the secret is missing", %{conn: conn} do
      {user, _secret} = seed_totp_user()
      codes = RecoveryCodes.generate()

      # `totp_enabled?` reads totp_confirmed_at, so this account is still
      # diverted to the second step — but has no secret to check a TOTP against.
      # Recovery codes are exactly the escape hatch for "the authenticator is
      # unavailable" and need no secret, so they must still land. Guarding the
      # whole check on the secret would leave such an account permanently
      # locked out of both surfaces, burning an attempt per try.
      user =
        Ash.Seed.update!(user, %{
          totp_secret: nil,
          totp_recovery_hashes: Enum.map(codes, &RecoveryCodes.hash/1)
        })

      pending = begin_two_factor(conn, user)
      conn = post_verify(conn, %{pending_token: pending, code: hd(codes)})

      assert %{"token" => _} = json_response(conn, 201)
    end

    test "missing fields are a 422", %{conn: conn} do
      conn = post_verify(conn, %{code: "123456"})

      assert %{"errors" => [%{"code" => "missing_parameters", "detail" => detail}]} =
               json_response(conn, 422)

      assert detail =~ "pending_token is required"
    end

    test "a code sent as a JSON number is a bad code, not a missing one", %{conn: conn} do
      {user, _secret} = seed_totp_user()

      pending = begin_two_factor(conn, user)
      conn = post_verify(conn, %{pending_token: pending, code: 123_456})

      # Both fields were supplied. Reporting `code` as missing sends the client
      # to debug its serialization of the *other* field, and the mistake is the
      # natural one: most TOTP libraries hand back an integer, and six digits
      # look like a number. (Leading zeros make it intermittent, which is worse
      # — `"012345"` stays a string.)
      assert %{"errors" => [%{"code" => "invalid_code"}]} = json_response(conn, 401)
    end
  end
end
