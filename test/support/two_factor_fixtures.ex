defmodule KilnCMS.TwoFactorFixtures do
  @moduledoc """
  Shared TOTP-test scaffolding (#746): a seeded second-factor account, the code
  that is valid right now, and recovery codes.

  The same home `KilnCMS.PasskeyFixtures` gives the other second factor, for the
  same reason its moduledoc gives — one place for the wire contract so the
  ceremony tests and the controller tests cannot drift apart. Four files were
  seeding a TOTP user by hand and six were spelling out
  `Totp.code_at(secret, System.system_time(:second))`.

  ## The clock

  A TOTP code is a function of a secret **and the current 30-second step**, so
  `current_code/1` reads the clock on every call rather than taking a timestamp.
  Anything that wants a code for a *different* step should say so with
  `KilnCMS.Accounts.Totp.code_at/2` and mean it — which is what `totp_test.exs`
  does, and why it is left alone.

  (What actually keeps these tests off a step boundary is `Totp`'s `@drift 1`,
  which accepts ±30s. The per-call clock read is tidiness, not the protection.)
  """

  alias KilnCMS.Accounts.{RecoveryCodes, Totp, User}

  @password "password123456"

  @doc "The password every seeded account here is given."
  def password, do: @password

  @doc """
  A confirmed account with TOTP already enabled, plus the secret its codes come
  from.

  Returns `{user, secret}` — every caller needs the secret to make a code, and
  taking it from the returned tuple rather than the struct keeps that true if the
  attribute is ever encrypted at rest.

  `opts` are merged into the seed, so `role:` (default `:admin`) or any other
  attribute can be set by a caller that cares. To pin the secret, pass
  `secret:` — **not** a non-nil `totp_secret:`, which raises: it would set the
  column while the returned tuple still carried a freshly minted random one, so
  `current_code/1` would produce a code that could never verify and a test
  asserting a refusal would pass for entirely the wrong reason. Every helper this
  replaced spelled the attribute name, so the mistake is the natural one to make.
  (`totp_secret: nil` is fine — an account with recovery codes and no TOTP
  factor, where the returned secret is meaningless anyway.)
  """
  @spec enabled_user(keyword()) :: {User.t(), binary()}
  def enabled_user(opts \\ []) do
    # Only a NON-NIL one lies: `totp_secret: nil` is a legitimate "an account
    # with recovery codes and no TOTP factor", where the returned secret is
    # meaningless and the caller ignores it.
    if is_binary(opts[:totp_secret]) do
      raise ArgumentError, """
      enabled_user/1 was passed `totp_secret:`, which would seed one secret and \
      return another — `current_code/1` on the returned one could never verify. \
      Pass `secret:` instead; it does both.\
      """
    end

    secret = Keyword.get_lazy(opts, :secret, fn -> :crypto.strong_rand_bytes(20) end)

    attrs =
      opts
      |> Keyword.drop([:secret])
      |> Map.new()
      |> then(
        &Map.merge(
          %{
            email: "totp-#{System.unique_integer([:positive])}@example.com",
            hashed_password: Bcrypt.hash_pwd_salt(@password),
            confirmed_at: DateTime.utc_now(),
            role: :admin,
            totp_secret: secret,
            totp_confirmed_at: DateTime.utc_now()
          },
          &1
        )
      )

    {Ash.Seed.seed!(User, attrs), secret}
  end

  @doc """
  The code `secret` accepts right now.

  Takes the secret or the user — a caller mid-enrolment holds a user whose
  pending secret is the one being confirmed, and asking for `totp_secret` there
  produces a code for the *old* factor, which is a confusing way to fail.
  """
  @spec current_code(binary() | User.t()) :: String.t()
  def current_code(%User{} = user),
    do: current_code(user.totp_pending_secret || user.totp_secret)

  def current_code(secret) when is_binary(secret),
    do: Totp.code_at(secret, System.system_time(:second))

  @doc """
  Issues recovery codes for `user`, returning `{user, codes}`.

  Seeded rather than generated through the action, like the rest of this module:
  the tests that need codes are testing what happens when one is *used*.
  """
  @spec with_recovery_codes(User.t()) :: {User.t(), [String.t()]}
  def with_recovery_codes(user) do
    codes = RecoveryCodes.generate()
    user = Ash.Seed.update!(user, %{totp_recovery_hashes: Enum.map(codes, &RecoveryCodes.hash/1)})

    {user, codes}
  end
end
