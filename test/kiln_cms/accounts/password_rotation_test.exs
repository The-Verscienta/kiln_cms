defmodule KilnCMS.Accounts.PasswordRotationTest do
  @moduledoc """
  A password change or reset revokes every stored token the account holds
  (#734) and drops its live sockets (#1637) — at the action, where it has to
  hold for every caller.

  `log_out_everywhere apply_on_password_change? true` was declared the whole
  time and revoked nothing: its change is gated on `hashed_password` being
  *touched*, evaluated when the changeset is built, and both actions write the
  hash in a `before_action`. So these assert on the token rows themselves, not
  on the presence of a flag. The end-to-end half — the old session and the
  remember-me cookie actually stop signing anyone in — is
  `KilnCMSWeb.PasswordRotationTest`.
  """
  use KilnCMS.DataCase, async: true

  import Ecto.Query

  alias KilnCMS.Accounts.Changes.RevokeAllTokens
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.Token
  alias KilnCMS.Accounts.User
  alias KilnCMS.Repo

  @password "password123456"
  @new_password "brand-new-password-789"

  defp user! do
    Ash.Seed.seed!(User, %{
      email: "rotate-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  # A real, stored JWT of each purpose that can authenticate — minted the way
  # the sign-in paths mint them, so each has a row a revocation can reach.
  defp mint!(user, purpose) do
    {:ok, token, %{"jti" => jti}} =
      case purpose do
        :user ->
          AshAuthentication.Jwt.token_for_user(user)

        :remember_me ->
          AshAuthentication.Jwt.token_for_user(user, %{"purpose" => "remember_me"},
            purpose: :remember_me,
            token_lifetime: {30, :days}
          )
      end

    {token, jti}
  end

  # A first-factor token parked at the code prompt (#742): the purpose flip
  # `PendingSignIn` makes, written directly because what matters here is the
  # row's state, not how it got there (`KilnCMSWeb.PasswordRotationTest` drives
  # the real prompt).
  defp hold!(user) do
    {_token, jti} = mint!(user, :user)

    {1, _} =
      Repo.update_all(from(t in "tokens", where: t.jti == ^jti),
        set: [purpose: Token.second_factor_hold_purpose()]
      )

    jti
  end

  defp purposes(user) do
    subject = AshAuthentication.user_to_subject(user)

    Repo.all(from t in "tokens", where: t.subject == ^subject, select: {t.jti, t.purpose})
    |> Map.new()
  end

  defp purpose(user, jti), do: Map.fetch!(purposes(user), jti)

  defp change_password(user, opts \\ []) do
    user
    |> Ash.Changeset.for_update(
      :change_password,
      %{
        current_password: @password,
        password: @new_password,
        password_confirmation: @new_password
      },
      actor: user
    )
    |> then(fn changeset ->
      case opts[:revoke] do
        nil -> changeset
        revoke -> RevokeAllTokens.change(changeset, [revoke: revoke], %{})
      end
    end)
    |> Ash.update()
  end

  defp reset_password(user) do
    strategy = AshAuthentication.Info.strategy!(User, :password)
    {:ok, reset_token} = AshAuthentication.Strategy.Password.reset_token_for(strategy, user)

    # The strategy's own entry point — what `/auth/user/password/reset` calls.
    AshAuthentication.Strategy.action(strategy, :reset, %{
      "reset_token" => reset_token,
      "password" => @new_password,
      "password_confirmation" => @new_password
    })
  end

  defp watch(user) do
    KilnCMSWeb.Endpoint.subscribe(SessionEviction.topic(user.id))
  end

  defp assert_evicted(user) do
    topic = SessionEviction.topic(user.id)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 2_000
  end

  defp refute_evicted(user) do
    topic = SessionEviction.topic(user.id)
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 200
  end

  for {name, rotate} <- [change_password: :change_password, reset: :reset_password] do
    describe "#{name}" do
      test "revokes every session, the remember-me token and a held sign-in" do
        user = user!()
        {_, session} = mint!(user, :user)
        {_, other_session} = mint!(user, :user)
        {_, remember_me} = mint!(user, :remember_me)
        held = hold!(user)

        assert purpose(user, session) == "user"
        assert purpose(user, remember_me) == "remember_me"
        assert purpose(user, held) == Token.second_factor_hold_purpose()

        assert {:ok, _} = unquote(rotate)(user)

        # `"revocation"` is the verdict `IsRevoked` reads — and a row off
        # `"user"` is one `require_token_presence_for_authentication?` refuses.
        for jti <- [session, other_session, remember_me, held] do
          assert purpose(user, jti) == "revocation"
        end
      end

      test "drops the account's live sockets" do
        user = user!()
        watch(user)

        assert {:ok, _} = unquote(rotate)(user)

        assert_evicted(user)
      end

      test "leaves other accounts' tokens alone" do
        user = user!()
        bystander = user!()
        {_, theirs} = mint!(bystander, :user)

        assert {:ok, _} = unquote(rotate)(user)

        assert purpose(bystander, theirs) == "user"
      end
    end
  end

  describe "reset_password_with_token" do
    # The reset signs its user in (`GenerateTokenChange`), so the sweep has to
    # run first or the owner is signed straight back out by their own reset.
    test "the session it signs the user into survives the sweep" do
      user = user!()
      {_, before} = mint!(user, :user)

      assert {:ok, reset} = reset_password(user)

      jti = KilnCMS.Accounts.Token.peeked_jti(reset.__metadata__.token)
      assert is_binary(jti)
      assert purpose(user, jti) == "user"
      assert purpose(user, before) == "revocation"
    end
  end

  describe "when the revocation fails" do
    # Fail closed: a password the user was told is changed, with the old
    # sessions still live, is the bug itself. The change has to take the whole
    # write down with it — the hash, and the rows already swept before the
    # failure.
    test "the password change rolls back and nothing is evicted" do
      user = user!()
      {_, session} = mint!(user, :user)
      watch(user)

      failing = fn _user, _context -> {:error, "revocation store unavailable"} end

      assert {:error, _} = change_password(user, revoke: failing)

      reloaded = Ash.get!(User, user.id, authorize?: false)
      assert reloaded.hashed_password == user.hashed_password
      assert Bcrypt.verify_pass(@password, reloaded.hashed_password)

      # The declared sweep ran first, inside the same transaction, and went
      # back with it.
      assert purpose(user, session) == "user"
      refute_evicted(user)
    end
  end
end
