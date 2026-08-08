defmodule KilnCMS.TwoFactorFixtures do
  @moduledoc """
  Shared TOTP-test scaffolding (#746): a seeded second-factor account, the code
  that is valid right now, and recovery codes.

  The same home `KilnCMS.PasskeyFixtures` gives the other second factor, for the
  same reason its moduledoc gives — one place for the wire contract so the
  ceremony tests and the controller tests cannot drift apart. Four files were
  seeding a TOTP user by hand and six were spelling out
  `Totp.code_at(secret, System.system_time(:second))`.

  ## The clock is the whole point

  A TOTP code is a function of a secret **and the current 30-second step**, so a
  test that mints one has to mint it at the moment it is used. `current_code/1`
  reads the clock on every call rather than taking a timestamp, which is what
  the six hand-written copies did; anything that wants a code for a *different*
  step should say so with `code_at/2` and mean it.
  """

  alias KilnCMS.Accounts.{RecoveryCodes, Totp, User}

  @password "password123456"

  @doc "The password every seeded account here is given."
  def password, do: @password

  @doc """
  A confirmed account with TOTP already enabled, plus the secret its codes come
  from.

  Returns `{user, secret}` — the secret is not derivable from the struct in a
  useful way once it is encrypted, and every caller needs it to make a code.

  `opts` are merged into the seed, so `role:` (default `:admin`) or any other
  attribute can be set by a caller that cares.
  """
  @spec enabled_user(keyword()) :: {User.t(), binary()}
  def enabled_user(opts \\ []) do
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
