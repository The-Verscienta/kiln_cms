defmodule KilnCMS.Accounts.PendingSignInTest do
  @moduledoc """
  The pending-sign-in blob, for both gates (#726, #745).

  #745 is an altitude issue rather than a bug report: the two doors each carried
  their own mint, resolve, lifetime and consume/verify/forgive, so the next
  hardening on the pending step would land on whichever one its author was
  looking at. These tests pin the properties that make one module *safe* to
  share — the two wrappings stay non-interchangeable, and neither mode leaks the
  other's fields — because a shared module that quietly merged the two would be
  worse than the duplication it replaced.

  `async: false`: the burn record is a node-wide Cachex instance.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts.PendingSignIn
  alias KilnCMS.TwoFactorFixtures

  @endpoint KilnCMSWeb.Endpoint

  defp enabled_user(extra \\ %{}) do
    {user, secret} =
      TwoFactorFixtures.enabled_user([role: :editor] ++ Enum.to_list(extra))

    # `PendingSignIn.mint/3` reads the first-factor token out of `__metadata__`,
    # which a seeded user does not carry — the sign-in strategy puts it there.
    {%{user | __metadata__: Map.put(user.__metadata__, :token, "stub.jwt.token")}, secret}
  end

  describe "round trip" do
    for mode <- [:session, :encrypted] do
      @mode mode

      test "#{mode}: carries the user and the first-factor token" do
        {user, _secret} = enabled_user()

        blob = PendingSignIn.mint(@mode, @endpoint, user)

        assert {:ok, pending} = PendingSignIn.resolve(@mode, @endpoint, blob)
        assert pending.user.id == user.id
        # Reattached so a completed sign-in has something to store.
        assert pending.user.__metadata__.token == "stub.jwt.token"
      end

      test "#{mode}: a garbage, missing or tampered blob is :error" do
        {user, _secret} = enabled_user()
        blob = PendingSignIn.mint(@mode, @endpoint, user)

        assert :error = PendingSignIn.resolve(@mode, @endpoint, "not-a-blob")
        assert :error = PendingSignIn.resolve(@mode, @endpoint, nil)
        assert :error = PendingSignIn.resolve(@mode, @endpoint, blob <> "x")
      end

      test "#{mode}: an account that turned 2FA off in between is refused" do
        # Honouring the blob anyway would complete a sign-in on a factor that no
        # longer exists.
        {user, _secret} = enabled_user()
        blob = PendingSignIn.mint(@mode, @endpoint, user)

        Ash.Seed.update!(user, %{totp_confirmed_at: nil})

        assert :error = PendingSignIn.resolve(@mode, @endpoint, blob)
      end
    end
  end

  describe "the two wrappings stay distinct" do
    test "a blob from one gate cannot be redeemed at the other" do
      # Separate salts. If these ever became interchangeable, a headless blob —
      # which the client *holds* — would be redeemable as a browser one.
      {user, _secret} = enabled_user()

      session = PendingSignIn.mint(:session, @endpoint, user)
      encrypted = PendingSignIn.mint(:encrypted, @endpoint, user)

      assert :error = PendingSignIn.resolve(:encrypted, @endpoint, session)
      assert :error = PendingSignIn.resolve(:session, @endpoint, encrypted)
    end

    test "the headless blob does not publish the first-factor JWT" do
      # The whole reason it is encrypted rather than signed: `Phoenix.Token.sign`
      # publishes its payload, and this payload carries the credential the
      # second factor exists to withhold. Reopening that would look like #726
      # fixed.
      {user, _secret} = enabled_user()

      encrypted = PendingSignIn.mint(:encrypted, @endpoint, user)
      refute decoded_anywhere?(encrypted, "stub.jwt.token")
    end

    test "the minted blob embeds five minutes, not Plug.Crypto's day" do
      # `Plug.Crypto.encode/2` writes `Keyword.get(opts, :max_age, 86400)` into
      # the term. A reader that supplies its own value wins, so this is not a
      # ceiling — `resolve/3` passes it for that. What the mint-time value buys
      # is the fallback for a reader that forgets: five minutes rather than a
      # day.
      #
      # Read out of the term rather than round-tripped, because a *round trip*
      # cannot tell 300 from 86400 without time travel — which is exactly how
      # the first version of this test passed with the option deleted.
      {user, _secret} = enabled_user()

      assert embedded_max_age(PendingSignIn.mint(:session, @endpoint, user)) ==
               PendingSignIn.max_age()

      # The signed mode is the one whose term is readable without the key, and
      # both modes go through the same `wrap/4`, so this covers the option
      # rather than the signing. The encrypted mode's round trip is pinned
      # above.
      assert embedded_max_age(Phoenix.Token.sign(@endpoint, "probe", %{}, max_age: 86_400)) ==
               86_400
    end
  end

  describe "single use" do
    test "an encrypted blob is refused once burned" do
      {user, _secret} = enabled_user()
      blob = PendingSignIn.mint(:encrypted, @endpoint, user)

      assert {:ok, %{jti: jti}} = PendingSignIn.resolve(:encrypted, @endpoint, blob)
      assert is_binary(jti)

      PendingSignIn.burn(jti)
      assert :error = PendingSignIn.resolve(:encrypted, @endpoint, blob)
    end

    test "a session blob carries no jti, and burning nil is a no-op" do
      # Its single use is the deleted session key. Minting a jti anyway would
      # add a cache write per browser sign-in against a replay that already
      # requires the session cookie.
      {user, _secret} = enabled_user()
      blob = PendingSignIn.mint(:session, @endpoint, user)

      assert {:ok, %{jti: nil}} = PendingSignIn.resolve(:session, @endpoint, blob)
      assert :ok = PendingSignIn.burn(nil)
    end
  end

  describe "remember-me intent" do
    test "survives the session round trip, and defaults to false" do
      {user, _secret} = enabled_user()

      ticked = PendingSignIn.mint(:session, @endpoint, user, remember_me?: true)
      plain = PendingSignIn.mint(:session, @endpoint, user)

      assert {:ok, %{remember_me?: true}} = PendingSignIn.resolve(:session, @endpoint, ticked)
      assert {:ok, %{remember_me?: false}} = PendingSignIn.resolve(:session, @endpoint, plain)
    end

    test "a headless blob never reports it, whatever was passed" do
      # There is no cookie to remember on a headless sign-in, so a caller must
      # not be able to read a `true` here and act on it.
      {user, _secret} = enabled_user()

      blob = PendingSignIn.mint(:encrypted, @endpoint, user, remember_me?: true)

      assert {:ok, %{remember_me?: remember?}} =
               PendingSignIn.resolve(:encrypted, @endpoint, blob)

      refute remember?
    end
  end

  # Does this token contain the needle in any base64-decodable segment? A signed
  # token would; an encrypted one must not.
  defp decoded_anywhere?(token, needle) do
    token
    |> String.split(".")
    |> Enum.any?(fn part ->
      case Base.url_decode64(part, padding: false) do
        {:ok, decoded} -> String.contains?(decoded, needle)
        :error -> String.contains?(part, needle)
      end
    end)
  end

  # `Plug.Crypto` signs `{data, signed_at, max_age}`; the payload segment of a
  # signed token is plain base64url, so the embedded lifetime is readable.
  defp embedded_max_age(blob) do
    [_protected, payload, _signature] = String.split(blob, ".")
    {:ok, binary} = Base.url_decode64(payload, padding: false)
    {_data, _signed_at, max_age} = Plug.Crypto.non_executable_binary_to_term(binary, [:safe])
    max_age
  end
end
