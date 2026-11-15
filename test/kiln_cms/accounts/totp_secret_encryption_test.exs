defmodule KilnCMS.Accounts.TotpSecretEncryptionTest do
  @moduledoc """
  TOTP secrets are stored as vault ciphertext: what the
  columns hold after enrolment, the rows from before that still have their
  secret in plaintext, and the backfill that moves them.

  The columns are read and written with SQL here on purpose: the point is what
  a dump of the table contains, which the `User` struct (plaintext in memory)
  cannot show.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.{SecondFactor, Totp, TotpSecretBackfill, TotpSecrets}
  alias KilnCMS.Keys.Vault
  alias KilnCMS.Repo
  alias KilnCMS.TwoFactorFixtures

  defp user(attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.User,
      Map.merge(
        %{
          email: "totp-enc-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        },
        attrs
      )
    )
  end

  @columns ~w(totp_secret totp_secret_encrypted totp_pending_secret totp_pending_secret_encrypted)a

  # The four columns as stored.
  defp columns(user) do
    %{rows: [row]} =
      Repo.query!(
        "SELECT #{Enum.join(@columns, ", ")} FROM users WHERE id = $1",
        [Ecto.UUID.dump!(user.id)]
      )

    @columns |> Enum.zip(row) |> Map.new()
  end

  # A row as the previous release left it: secrets in the plaintext columns.
  defp put_legacy(user, set) do
    {assignments, params} =
      set
      |> Enum.with_index(2)
      |> Enum.map(fn {{column, value}, i} -> {"#{column} = $#{i}", value} end)
      |> Enum.unzip()

    Repo.query!(
      "UPDATE users SET #{Enum.join(assignments, ", ")} WHERE id = $1",
      [Ecto.UUID.dump!(user.id) | params]
    )

    reload(user)
  end

  defp reload(user), do: Accounts.get_user!(user.id, authorize?: false)

  defp code(secret), do: TwoFactorFixtures.current_code(secret)

  defp refute_contains(stored, secret) when is_binary(stored) do
    refute stored == secret
    assert :binary.match(stored, secret) == :nomatch
  end

  describe "enrolment" do
    test "stores the staged and the live secret encrypted, never in plaintext" do
      user = user()

      {:ok, staged} = Accounts.setup_totp(user, %{}, actor: user)
      pending = TotpSecrets.pending(staged)
      assert byte_size(pending) == 20

      stored = columns(staged)
      assert stored.totp_pending_secret == nil
      refute_contains(stored.totp_pending_secret_encrypted, pending)
      assert {:ok, ^pending} = Vault.decrypt(stored.totp_pending_secret_encrypted)

      {:ok, confirmed} = Accounts.confirm_totp(staged, %{code: code(pending)}, actor: staged)
      assert Accounts.totp_enabled?(confirmed)

      stored = columns(confirmed)
      assert stored.totp_secret == nil
      assert stored.totp_pending_secret == nil
      assert stored.totp_pending_secret_encrypted == nil
      refute_contains(stored.totp_secret_encrypted, pending)
      assert {:ok, ^pending} = Vault.decrypt(stored.totp_secret_encrypted)

      # Read back from the database, the struct holds the plaintext again.
      assert reload(confirmed).totp_secret == pending
    end

    test "a code from the encrypted secret verifies at sign-in" do
      {user, secret} = TwoFactorFixtures.enabled_user()
      assert columns(user).totp_secret == nil

      assert {:ok, _} = SecondFactor.check(reload(user), code(secret))
      assert :invalid = SecondFactor.check(reload(user), "000000")
    end

    test "disabling clears every column, the plaintext ones included" do
      {user, secret} = TwoFactorFixtures.enabled_user()
      user = put_legacy(user, totp_pending_secret: Totp.generate_secret())

      {:ok, _} = Accounts.disable_totp(user, %{code: code(secret)}, actor: user)

      assert columns(user) == Map.new(@columns, &{&1, nil})
    end
  end

  describe "a row from before the encryption" do
    test "its plaintext live secret still verifies" do
      secret = Totp.generate_secret()
      user = put_legacy(user(%{totp_confirmed_at: DateTime.utc_now()}), totp_secret: secret)

      assert user.totp_secret == nil
      assert TotpSecrets.live(user) == secret
      assert {:ok, _} = SecondFactor.check(user, code(secret))

      assert {:ok, _} =
               Accounts.regenerate_totp_recovery_codes(user, %{code: code(secret)}, actor: user)
    end

    test "its plaintext staged secret confirms, and the result is stored encrypted" do
      pending = Totp.generate_secret()
      user = put_legacy(user(), totp_pending_secret: pending)

      {:ok, confirmed} = Accounts.confirm_totp(user, %{code: code(pending)}, actor: user)
      assert Accounts.totp_enabled?(confirmed)

      stored = columns(confirmed)
      assert stored.totp_secret == nil
      assert stored.totp_pending_secret == nil
      assert {:ok, ^pending} = Vault.decrypt(stored.totp_secret_encrypted)
    end

    test "re-enrolling replaces the plaintext live secret with an encrypted one" do
      old = Totp.generate_secret()
      user = put_legacy(user(%{totp_confirmed_at: DateTime.utc_now()}), totp_secret: old)

      {:ok, staged} = Accounts.setup_totp(user, %{}, actor: user)
      new = TotpSecrets.pending(staged)

      {:ok, swapped} =
        Accounts.confirm_totp(staged, %{code: code(new), current_code: code(old)}, actor: staged)

      assert TotpSecrets.live(reload(swapped)) == new
      assert columns(swapped).totp_secret == nil
    end

    # A node of the previous release re-enrolled the account during a rolling
    # deploy: it wrote the plaintext column and left the old ciphertext.
    test "a plaintext secret wins over a stale encrypted one" do
      {user, stale} = TwoFactorFixtures.enabled_user()
      fresh = Totp.generate_secret()
      user = put_legacy(user, totp_secret: fresh)

      assert user.totp_secret == stale
      assert TotpSecrets.live(user) == fresh
      assert {:ok, _} = SecondFactor.check(user, code(fresh))
    end
  end

  describe "the backfill" do
    test "moves plaintext secrets into the encrypted columns, then has nothing to do" do
      live = Totp.generate_secret()
      pending = Totp.generate_secret()

      user =
        put_legacy(user(%{totp_confirmed_at: DateTime.utc_now()}),
          totp_secret: live,
          totp_pending_secret: pending
        )

      assert %{encrypted: 1} = TotpSecretBackfill.run()

      stored = columns(user)
      assert stored.totp_secret == nil
      assert stored.totp_pending_secret == nil
      refute_contains(stored.totp_secret_encrypted, live)
      assert {:ok, ^live} = Vault.decrypt(stored.totp_secret_encrypted)
      assert {:ok, ^pending} = Vault.decrypt(stored.totp_pending_secret_encrypted)

      assert {:ok, _} = SecondFactor.check(reload(user), code(live))

      assert TotpSecretBackfill.run() == %{encrypted: 0, orphans_dropped: 0, erased_cleared: 0}
      assert columns(user) == stored
    end

    test "leaves an already-encrypted account alone" do
      {user, _secret} = TwoFactorFixtures.enabled_user()
      before = columns(user)

      assert TotpSecretBackfill.run() == %{encrypted: 0, orphans_dropped: 0, erased_cleared: 0}
      assert columns(user) == before
    end

    # A node of the previous release disabled the factor: it cleared the
    # plaintext column and `totp_confirmed_at`, and left the ciphertext.
    test "drops an encrypted secret whose factor was turned off" do
      {user, _secret} = TwoFactorFixtures.enabled_user()
      Ash.Seed.update!(user, %{totp_confirmed_at: nil})

      assert %{orphans_dropped: 1} = TotpSecretBackfill.run()
      assert columns(user).totp_secret_encrypted == nil
    end

    test "clears every secret column of an erased account" do
      {user, _secret} = TwoFactorFixtures.enabled_user()
      Ash.Seed.update!(user, %{anonymized_at: DateTime.utc_now()})
      put_legacy(user, totp_pending_secret: Totp.generate_secret())

      assert %{erased_cleared: 1} = TotpSecretBackfill.run()
      assert columns(user) == Map.new(@columns, &{&1, nil})
    end

    test "revert/0 writes the secrets back to the plaintext columns for a rollback" do
      {user, secret} = TwoFactorFixtures.enabled_user()

      assert %{restored: 1, unreadable: 0} = TotpSecretBackfill.revert()

      stored = columns(user)
      assert stored.totp_secret == secret
      assert {:ok, ^secret} = Vault.decrypt(stored.totp_secret_encrypted)
      assert {:ok, _} = SecondFactor.check(reload(user), code(secret))
    end
  end

  test "a secret that opens under no known key loads as nil instead of raising" do
    {user, _secret} = TwoFactorFixtures.enabled_user()
    other_key = "another-secret-key-base-" <> String.duplicate("x", 64)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        loaded = put_legacy(user, totp_secret_encrypted: Vault.encrypt("seed", other_key))
        assert loaded.totp_secret == nil
        assert Accounts.totp_enabled?(loaded)
      end)

    assert log =~ "did not decrypt"
  end
end
