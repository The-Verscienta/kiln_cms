defmodule KilnCMS.Accounts.SecondFactorHoldContractTest do
  @moduledoc """
  Pins the #742 hold against **AshAuthentication itself**, not against Kiln's
  callers (#1172).

  The hold works by moving a stored token's `purpose` off `"user"`, because the
  dep's `validate_token/3` looks the row up under exactly that purpose. Every
  other test of the hold asserts through `KilnCMSWeb.BearerAuth`, which restates
  the same lookup — so if a future AshAuthentication *widened* its filter (a
  list of purposes, `purpose != "revocation"`), the hold would still write
  `pending_second_factor`, the token would still authenticate, and every one of
  those tests would stay green. These drive a held token through the dep's own
  entry points, and are the ones that go red on a widening.

  A *rename* of the purpose would go red everywhere anyway; the widening is the
  quiet failure and the one worth a test of its own.
  """
  use KilnCMS.DataCase, async: false

  require Ash.Query

  alias AshAuthentication.Info
  alias AshAuthentication.Plug.Helpers, as: AuthHelpers
  alias AshAuthentication.TokenResource.Actions, as: TokenActions
  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Token
  alias KilnCMS.Accounts.User
  alias KilnCMS.Accounts.Verifiers.SecondFactorHoldContract
  alias KilnCMS.TwoFactorFixtures

  @otp_app :kiln_cms

  describe "the dep's own lookup refuses a held token" do
    test "get_token/3 under the \"user\" purpose finds the row before the hold and not after" do
      {_user, token, jti} = stored_token()

      # Precondition, asserted through the dep: this is the exact call
      # `validate_token/3` makes, so a green here means the row is what the dep
      # would authenticate against.
      assert {:ok, [%Token{purpose: "user"}]} =
               TokenActions.get_token(Token, %{"jti" => jti, "purpose" => "user"})

      hold!(jti)

      assert {:ok, []} = TokenActions.get_token(Token, %{"jti" => jti, "purpose" => "user"})
      # The row still exists — it is parked, not gone. This is what distinguishes
      # a hold from a revocation, and what `claim/1` puts back.
      assert {:ok, %Token{purpose: "pending_second_factor"}} =
               Accounts.get_stored_token_by_jti(jti, authorize?: false)

      # And the token itself is unchanged: only the store's view of it moved.
      assert {:ok, %{"jti" => ^jti}, User} = AshAuthentication.Jwt.verify(token, @otp_app)
    end
  end

  describe "the dep's full round trip refuses a held token — the half that survives a widening" do
    test "retrieve_from_bearer/3 assigns the user before the hold and nil after" do
      {user, token, jti} = stored_token()

      conn = AuthHelpers.retrieve_from_bearer(bearer_conn(token), @otp_app)
      assert %User{id: id} = conn.assigns.current_user
      assert id == user.id

      hold!(jti)

      conn = AuthHelpers.retrieve_from_bearer(bearer_conn(token), @otp_app)

      # `retrieve_from_bearer/3` leaves the assign untouched when the token does
      # not validate, so "not set" is the refusal — not an explicit `nil`.
      refute Map.has_key?(conn.assigns, :current_user),
             "a held first-factor token authenticated through AshAuthentication's bearer path"
    end

    test "authenticate_resource_from_session/4 accepts before the hold and refuses after" do
      {user, token, jti} = stored_token()
      session = %{"user_token" => token}

      assert {:ok, %User{id: id}} =
               AuthHelpers.authenticate_resource_from_session(User, session, @otp_app, [])

      assert id == user.id

      hold!(jti)

      assert :error =
               AuthHelpers.authenticate_resource_from_session(User, session, @otp_app, []),
             "a held first-factor token authenticated through AshAuthentication's session path"
    end
  end

  describe "the compile-time contract (#1172)" do
    # `KilnCMS.Accounts.SecondFactorHoldExtension` runs this verifier against
    # `User` at compile time; these exercise it directly against the resource's
    # real DSL state so the red path is proven rather than assumed. (Flipping
    # the setting in `user.ex` and watching the compile fail was done by hand
    # once — this is the version that stays.)
    test "User's live settings satisfy it" do
      assert Info.authentication_tokens_require_token_presence_for_authentication?(User)
      assert Info.authentication_tokens_store_all_tokens?(User)
      assert {:ok, Token} = Info.authentication_tokens_token_resource(User)

      assert :ok = SecondFactorHoldContract.verify(User.spark_dsl_config())
    end

    test "turning off require_token_presence_for_authentication? is a DslError naming the hold" do
      dsl = set_token_option(:require_token_presence_for_authentication?, false)

      assert {:error, %Spark.Error.DslError{message: message, path: path}} =
               SecondFactorHoldContract.verify(dsl)

      assert path == [:authentication, :tokens, :require_token_presence_for_authentication?]
      assert message =~ "#742"
      assert message =~ "#1172"
    end

    test "turning off store_all_tokens? is a DslError too" do
      dsl = set_token_option(:store_all_tokens?, false)

      assert {:error, %Spark.Error.DslError{path: path}} = SecondFactorHoldContract.verify(dsl)
      assert path == [:authentication, :tokens, :store_all_tokens?]
    end

    test "pointing token_resource elsewhere is a DslError" do
      dsl = set_token_option(:token_resource, KilnCMS.Accounts.ApiKey)

      assert {:error, %Spark.Error.DslError{path: path, message: message}} =
               SecondFactorHoldContract.verify(dsl)

      assert path == [:authentication, :tokens, :token_resource]
      assert message =~ "KilnCMS.Accounts.ApiKey"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # A 2FA account with a first-factor JWT the store has actually seen, exactly
  # as the password strategy leaves it. Returns the jti too, since every
  # assertion here keys on it.
  defp stored_token do
    {user, _secret} = TwoFactorFixtures.enabled_user(role: :editor)
    {user, token} = TwoFactorFixtures.with_first_factor_token(user)
    {user, token, Token.peeked_jti(token)}
  end

  # The hold, taken through the row action rather than through
  # `PendingSignIn`, so this file pins the *purpose move* against the dep and
  # nothing else — whatever the mint entry point is called this week.
  defp hold!(jti) do
    %Ash.BulkResult{status: :success, records: [_]} =
      Token
      |> Ash.Query.filter(jti == ^jti)
      |> Ash.bulk_update!(:hold_for_second_factor, %{},
        strategy: :atomic,
        authorize?: false,
        return_records?: true,
        return_errors?: true
      )

    :ok
  end

  defp bearer_conn(token) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
  end

  # `User`'s real DSL state with one `authentication.tokens` option rewritten —
  # what the verifier would see if someone edited `user.ex` that way.
  defp set_token_option(key, value) do
    Spark.Dsl.Transformer.set_option(
      User.spark_dsl_config(),
      [:authentication, :tokens],
      key,
      value
    )
  end
end
