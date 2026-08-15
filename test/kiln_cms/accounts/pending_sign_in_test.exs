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

  `async: false`: the single-use record is a row in the shared `tokens` table,
  keyed on the blob's jti (#743).
  """
  use KilnCMS.DataCase, async: false

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.PendingSignIn
  alias KilnCMS.Accounts.Token
  alias KilnCMS.TwoFactorFixtures

  @endpoint KilnCMSWeb.Endpoint

  defp enabled_user(extra \\ %{}) do
    {user, secret} =
      TwoFactorFixtures.enabled_user([role: :editor] ++ Enum.to_list(extra))

    # `PendingSignIn.mint_and_hold/4` reads the first-factor token out of `__metadata__`,
    # which a seeded user does not carry — the sign-in strategy puts it there.
    {%{user | __metadata__: Map.put(user.__metadata__, :token, "stub.jwt.token")}, secret}
  end

  describe "round trip" do
    for mode <- [:session, :encrypted] do
      @mode mode

      test "#{mode}: carries the user and the first-factor token" do
        {user, _secret} = enabled_user()

        blob = PendingSignIn.mint_and_hold(@mode, @endpoint, user)

        assert {:ok, pending} = PendingSignIn.resolve(@mode, @endpoint, blob)
        assert pending.user.id == user.id
        # Reattached so a completed sign-in has something to store.
        assert pending.user.__metadata__.token == "stub.jwt.token"
      end

      test "#{mode}: a garbage, missing or tampered blob is :error" do
        {user, _secret} = enabled_user()
        blob = PendingSignIn.mint_and_hold(@mode, @endpoint, user)

        assert :error = PendingSignIn.resolve(@mode, @endpoint, "not-a-blob")
        assert :error = PendingSignIn.resolve(@mode, @endpoint, nil)
        assert :error = PendingSignIn.resolve(@mode, @endpoint, blob <> "x")
      end

      test "#{mode}: an account that turned 2FA off in between is refused" do
        # Honouring the blob anyway would complete a sign-in on a factor that no
        # longer exists.
        {user, _secret} = enabled_user()
        blob = PendingSignIn.mint_and_hold(@mode, @endpoint, user)

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

      session = PendingSignIn.mint_and_hold(:session, @endpoint, user)
      encrypted = PendingSignIn.mint_and_hold(:encrypted, @endpoint, user)

      assert :error = PendingSignIn.resolve(:encrypted, @endpoint, session)
      assert :error = PendingSignIn.resolve(:session, @endpoint, encrypted)
    end

    test "the headless blob does not publish the first-factor JWT" do
      # The whole reason it is encrypted rather than signed: `Phoenix.Token.sign`
      # publishes its payload, and this payload carries the credential the
      # second factor exists to withhold. Reopening that would look like #726
      # fixed.
      {user, _secret} = enabled_user()

      encrypted = PendingSignIn.mint_and_hold(:encrypted, @endpoint, user)
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

      assert embedded_max_age(PendingSignIn.mint_and_hold(:session, @endpoint, user)) ==
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
    test "an encrypted blob carries a jti, and claiming it succeeds once" do
      {user, _secret} = enabled_user()
      blob = PendingSignIn.mint_and_hold(:encrypted, @endpoint, user)

      assert {:ok, %{jti: jti} = resolved} = PendingSignIn.resolve(:encrypted, @endpoint, blob)
      assert is_binary(jti)
      assert :ok = PendingSignIn.claim(resolved)

      # `resolve/3` still succeeds on a spent blob — there is deliberately no
      # "is it spent?" read (see the moduledoc). The claim is the gate, and it
      # is what refuses the second redemption.
      assert {:ok, again} = PendingSignIn.resolve(:encrypted, @endpoint, blob)
      assert :taken = PendingSignIn.claim(again)
    end

    test "spending the SAME blob twice loses the second time" do
      # The guarantee, and the whole point of #743: the record is an INSERT on
      # the jti, so a replay that also holds a valid code cannot be told it was
      # first. A node-local cache answered "unspent" on every node that had not
      # seen the redemption.
      {user, _secret} = enabled_user()
      blob = PendingSignIn.mint_and_hold(:encrypted, @endpoint, user)

      assert {:ok, resolved} = PendingSignIn.resolve(:encrypted, @endpoint, blob)

      assert :ok = PendingSignIn.claim(resolved)
      assert :taken = PendingSignIn.claim(resolved)
    end

    test "the claim record outlives the blob it retires" do
      # Otherwise there is a window in which the blob is still inside its
      # `max_age` but the record of its use has expired — a replay that only has
      # to be patient. The two constants live in different modules, so nothing
      # but this stops one being changed without the other.
      assert KilnCMS.Accounts.Token.pending_sign_in_ttl() > PendingSignIn.max_age()
    end

    test "a session blob carries no jti, and spending it is a no-op" do
      # Its single use is the deleted session key. Minting a jti anyway would
      # add a write per browser sign-in against a replay that already requires
      # the session cookie.
      {user, _secret} = enabled_user()
      blob = PendingSignIn.mint_and_hold(:session, @endpoint, user)

      assert {:ok, %{jti: nil} = resolved} = PendingSignIn.resolve(:session, @endpoint, blob)
      assert :ok = PendingSignIn.claim(resolved)
    end
  end

  describe "remember-me intent" do
    test "survives the session round trip, and defaults to false" do
      {user, _secret} = enabled_user()

      ticked = PendingSignIn.mint_and_hold(:session, @endpoint, user, remember_me?: true)
      plain = PendingSignIn.mint_and_hold(:session, @endpoint, user)

      assert {:ok, %{remember_me?: true}} = PendingSignIn.resolve(:session, @endpoint, ticked)
      assert {:ok, %{remember_me?: false}} = PendingSignIn.resolve(:session, @endpoint, plain)
    end

    test "a headless blob never reports it, whatever was passed" do
      # There is no cookie to remember on a headless sign-in, so a caller must
      # not be able to read a `true` here and act on it.
      {user, _secret} = enabled_user()

      blob = PendingSignIn.mint_and_hold(:encrypted, @endpoint, user, remember_me?: true)

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

  describe "the first-factor token is held for the length of the step (#742)" do
    # `store_all_tokens?` mints AND stores the first-factor JWT before either
    # controller learns the account owes a code, so the step used to leave a
    # live, usable row that nobody holds — for the JWT's full lifetime. These
    # pin the hold on BOTH gates, because the browser flow has the same shape
    # and #742's own notes say so.
    for mode <- [:session, :encrypted] do
      @mode mode

      test "#{mode}: minting moves the stored token off the purpose auth requires" do
        {user, token} = held_user()

        assert usable?(token), "precondition: a freshly stored token authenticates"

        PendingSignIn.mint_and_hold(@mode, @endpoint, user)

        refute usable?(token)
        assert row(token).purpose == Token.second_factor_hold_purpose()
      end

      test "#{mode}: claiming puts it back, with the expiry the JWT itself carries" do
        {user, token} = held_user()
        expiry = row(token).expires_at

        blob = PendingSignIn.mint_and_hold(@mode, @endpoint, user)
        assert {:ok, resolved} = PendingSignIn.resolve(@mode, @endpoint, blob)

        assert :ok = PendingSignIn.claim(resolved)

        assert usable?(token)
        # Not the hold's minutes: a released token has to be worth what the JWT
        # in it says, or a completed sign-in expires in the middle of the step
        # that completed it.
        assert row(token).expires_at == expiry
      end

      test "#{mode}: an abandoned exchange leaves nothing usable, and nothing long-lived" do
        {user, token} = held_user()
        natural = row(token).expires_at

        PendingSignIn.mint_and_hold(@mode, @endpoint, user)

        refute usable?(token)

        # The whole cost #742 names: without this the row sits live until the
        # JWT's own expiry, which is weeks away, and the nightly expunge is no
        # help inside that. Held, it is collectable within a day of this step.
        held = row(token).expires_at
        assert DateTime.compare(held, natural) == :lt

        assert DateTime.diff(held, DateTime.utc_now()) <= Token.second_factor_hold_ttl()
      end
    end

    test "a release does not resurrect a token that was revoked in between" do
      # A password change fires `log_out_everywhere` and an erasure fires
      # `AnonymizeUser`; both move the row to `"revocation"`. A release that
      # restored unconditionally would undo that for anyone holding a
      # five-minute-old blob and a live code — so it is filtered on the hold
      # purpose, in the UPDATE's own WHERE, and finds nothing to put back.
      {user, token} = held_user()

      blob = PendingSignIn.mint_and_hold(:encrypted, @endpoint, user)
      Ash.Seed.update!(row(token), %{purpose: "revocation"})

      assert {:ok, resolved} = PendingSignIn.resolve(:encrypted, @endpoint, blob)

      # `:unavailable`, not `:ok`. The token cannot be made usable, and saying
      # otherwise hands the caller a 201 carrying a revoked credential whose
      # only symptom is a 401 on every request after it.
      assert :unavailable = PendingSignIn.claim(resolved)

      refute usable?(token)
      assert row(token).purpose == "revocation"
    end

    test "a claim that loses the race does not release the token" do
      # The ordering, pinned. Releasing before claiming reads better on a
      # release failure, and fails in the wrong direction on a claim failure:
      # the token goes back to `"user"` with its full natural expiry and the
      # caller is refused, so nobody holds it — #742 verbatim, re-created by the
      # code that closes it.
      {user, token} = held_user()

      blob = PendingSignIn.mint_and_hold(:encrypted, @endpoint, user)
      assert {:ok, resolved} = PendingSignIn.resolve(:encrypted, @endpoint, blob)

      # Someone else spends this blob's jti first.
      assert :ok =
               Accounts.spend_pending_sign_in(
                 %{jti: resolved.jti, subject: AshAuthentication.user_to_subject(user)},
                 authorize?: false
               )
               |> then(fn {:ok, _} -> :ok end)

      assert :taken = PendingSignIn.claim(resolved)

      # Still parked. A loser must move nothing.
      refute usable?(token)
      assert row(token).purpose == Token.second_factor_hold_purpose()
    end

    test "a hold that has lapsed can still be released by jti" do
      # Before #1173, release went through `get_token`, which filters
      # `expires_at > now()` — so a lapsed hold was invisible and claim answered
      # `:unavailable`, leaving a parked credential. The atomic UPDATE filters by
      # jti + purpose only, so a hold that outlived its window can still be put
      # back under `"user"` with the JWT's own expiry.
      {user, token} = held_user()

      blob = PendingSignIn.mint_and_hold(:encrypted, @endpoint, user)
      Ash.Seed.update!(row(token), %{expires_at: DateTime.add(DateTime.utc_now(), -5, :second)})

      assert {:ok, resolved} = PendingSignIn.resolve(:encrypted, @endpoint, blob)
      assert :ok = PendingSignIn.claim(resolved)
      assert usable?(token)
      assert row(token).purpose == Token.user_purpose()
    end

    test "a token the store never held does not refuse the sign-in" do
      # The other side of fail-soft, and the reason the release keys on whether a
      # row exists rather than on whether one is held. If the store stops holding
      # first-factor tokens at all — `store_all_tokens?` turned off, an
      # AshAuthentication purpose renamed, this resource regenerated — the hold
      # logs and carries on. A release that refused on the same fault would turn
      # that deployment into "no account with a second factor can sign in",
      # which is the outcome the fail-soft half exists to rule out.
      {user, token} = held_user()

      blob = PendingSignIn.mint_and_hold(:encrypted, @endpoint, user)
      KilnCMS.Repo.delete!(row(token))

      assert {:ok, resolved} = PendingSignIn.resolve(:encrypted, @endpoint, blob)
      assert :ok = PendingSignIn.claim(resolved)
    end

    test "a re-mint re-takes the hold rather than leaving the first one to lapse" do
      # The blob's window restarts on every mint; the hold's does not, unless it
      # is re-taken. A re-mint that no-ops leaves a blob redeemable past the
      # moment its own hold expires.
      {user, token} = held_user()

      PendingSignIn.mint_and_hold(:encrypted, @endpoint, user)
      first = row(token).expires_at

      Ash.Seed.update!(row(token), %{expires_at: DateTime.add(first, -120, :second)})
      PendingSignIn.mint_and_hold(:encrypted, @endpoint, user)

      assert DateTime.compare(row(token).expires_at, first) in [:eq, :gt]
      assert row(token).purpose == Token.second_factor_hold_purpose()
    end

    test "a revocation landing between the read and the hold is not overwritten" do
      # The purpose filter rides in the UPDATE's WHERE. Staged rather than raced:
      # `Ash.Seed.update!` writes `"revocation"` before the bulk hold runs, which
      # is exactly the interleaving a password-change `log_out_everywhere` would
      # produce against `PendingSignIn`'s single-statement hold (#1173).
      {_user, token} = held_user()
      {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)
      Ash.Seed.update!(row(token), %{purpose: "revocation"})

      result =
        Token
        |> Ash.Query.filter(jti == ^jti)
        |> Ash.bulk_update(:hold_for_second_factor, %{},
          strategy: :atomic,
          authorize?: false,
          return_records?: true
        )

      assert result.records in [[], nil]
      assert row(token).purpose == "revocation"
    end

    test "a revocation landing between the read and the release is not overwritten" do
      # The same race on the half that grants use, where losing it un-revokes a
      # credential the user just revoked and restores its full natural expiry.
      {_user, token} = held_user()
      {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)
      Ash.Seed.update!(row(token), %{purpose: Token.second_factor_hold_purpose()})
      Ash.Seed.update!(row(token), %{purpose: "revocation"})
      expires_at = Token.peeked_expires_at(token)

      result =
        Token
        |> Ash.Query.filter(jti == ^jti)
        |> Ash.bulk_update(:release_second_factor_hold, %{expires_at: expires_at},
          strategy: :atomic,
          authorize?: false,
          return_records?: true
        )

      assert result.records in [[], nil]
      assert row(token).purpose == "revocation"
    end

    test "neither action is reachable without the system's own authorize?: false" do
      # Both are `forbid_if always()`. Every other test here passes
      # `authorize?: false`, so without this one the policy block could be
      # deleted and the suite would stay green.
      {_user, token} = held_user()
      record = row(token)
      expires_at = Token.peeked_expires_at(token)

      assert {:error, %Ash.Error.Forbidden{}} = Accounts.hold_first_factor_token(record, %{})

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.release_first_factor_token(record, %{expires_at: expires_at})
    end

    test "the hold refuses a row that is not a usable stored token" do
      # `"revocation"` is not in the purpose list, and that is the whole point of
      # listing. Exercised through the same bulk filter `PendingSignIn` uses
      # (#1173), because a record-shaped code-interface update is not the
      # production path.
      {_user, token} = held_user()
      {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)
      Ash.Seed.update!(row(token), %{purpose: "revocation"})

      result =
        Token
        |> Ash.Query.filter(jti == ^jti)
        |> Ash.bulk_update(:hold_for_second_factor, %{},
          strategy: :atomic,
          authorize?: false,
          return_records?: true
        )

      assert result.records in [[], nil]
      assert row(token).purpose == "revocation"
    end

    test "a release bulk-update for the wrong jti leaves the held row untouched" do
      # Before #1173, `StoreTokenChange` wrote `jti` from the token argument and
      # could rename a held row. The atomic form filters by jti instead, so a
      # UPDATE aimed at a different primary key is a no-op.
      {_mine, mine} = held_user()
      {_theirs, theirs} = held_user()
      KilnCMS.Repo.delete!(row(theirs))

      _held = Ash.Seed.update!(row(mine), %{purpose: Token.second_factor_hold_purpose()})
      {:ok, %{"jti" => theirs_jti}} = AshAuthentication.Jwt.peek(theirs)
      mine_exp = Token.peeked_expires_at(mine)

      result =
        Token
        |> Ash.Query.filter(jti == ^theirs_jti)
        |> Ash.bulk_update(:release_second_factor_hold, %{expires_at: mine_exp},
          strategy: :atomic,
          authorize?: false,
          return_records?: true
        )

      assert result.records == [] or result.records == nil
      assert row(mine).purpose == Token.second_factor_hold_purpose()

      assert {:ok, _} =
               Accounts.release_first_factor_token(row(mine), %{expires_at: mine_exp},
                 authorize?: false
               )

      assert row(mine).purpose == Token.user_purpose()
    end

    test "the hold outlives the blob it is holding for" do
      # `GetTokenPreparation` filters `expires_at > now()`, so a hold that lapses
      # while the blob is still redeemable is a token nobody can put back — the
      # caller gets a 201 and a credential that answers 401. The two constants
      # live in different modules, so nothing but this stops one moving.
      assert Token.second_factor_hold_ttl() > PendingSignIn.max_age()
    end

    test "a blob carrying something that is not a JWT neither raises nor holds" do
      # `Joken.peek_claims/1` raises on anything that is not a well-formed token,
      # and `mint_and_hold/4` is on the sign-in path: an absence has to stay an absence.
      {user, _secret} = enabled_user()

      assert is_binary(
               PendingSignIn.mint_and_hold(:encrypted, @endpoint, user, token: "stub.jwt.token")
             )
    end
  end

  describe "mint_and_hold/4 refuses the caller's own credential (#1171)" do
    # The hold is a side effect a caller cannot opt out of, so the one call it
    # must never accept is a step-up prompt handing over the token that
    # authenticates the request itself — that would sign the caller out.
    # A first-factor sign-in never trips this: the strategy's fresh token is not
    # the one (if any) the request arrived with.
    test "raises when the token is the conn's session credential, and holds nothing" do
      {user, token} = held_user()

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{"user_token" => token})

      assert_raise ArgumentError, ~r/would sign the caller out/, fn ->
        PendingSignIn.mint_and_hold(:session, conn, user)
      end

      assert usable?(token), "a refused hold must leave the session's token untouched"
    end

    test "raises when the token is the conn's bearer credential" do
      {user, token} = held_user()

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.assign(:current_user, user)

      assert_raise ArgumentError, ~r/would sign the caller out/, fn ->
        PendingSignIn.mint_and_hold(:encrypted, conn, user, token: token)
      end

      assert usable?(token)
    end

    test "a conn authenticated by a DIFFERENT token is fine — that is a plain sign-in" do
      {user, fresh} = held_user()
      {_same_user, other} = TwoFactorFixtures.with_first_factor_token(user)

      conn = Plug.Test.init_test_session(endpoint_conn(), %{"user_token" => other})

      blob = PendingSignIn.mint_and_hold(:session, conn, user, token: fresh)

      assert is_binary(blob)
      refute usable?(fresh)
      assert usable?(other), "only the token being minted is held, never the request's"
    end

    test "a conn with no session fetched and no current user is a plain sign-in" do
      {user, token} = held_user()

      blob = PendingSignIn.mint_and_hold(:encrypted, endpoint_conn(), user)

      assert is_binary(blob)
      refute usable?(token)
    end
  end

  # A conn `Phoenix.Token` can key off, as one that has been through the
  # endpoint would be.
  defp endpoint_conn,
    do: Plug.Conn.put_private(Phoenix.ConnTest.build_conn(), :phoenix_endpoint, @endpoint)

  # A 2FA account carrying a first-factor token the store has actually seen.
  defp held_user do
    {user, _secret} = enabled_user()
    TwoFactorFixtures.with_first_factor_token(user)
  end

  # The exact question `BearerAuth.user_from_token/1` and the session plug both
  # ask: is there a row for this jti under the `"user"` purpose?
  defp usable?(token), do: match?({:ok, _user}, KilnCMSWeb.BearerAuth.user_from_token(token))

  defp row(token) do
    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)
    Ash.get!(Token, jti, authorize?: false)
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
