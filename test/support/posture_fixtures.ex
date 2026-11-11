defmodule KilnCMS.PostureFixtures do
  @moduledoc """
  Shared scaffolding for the Security posture checks' tests (#2252): accounts
  and memberships seeded the way the rest of the suite seeds them, a real
  TOTP enrolment (through `:setup_totp` and `:confirm_totp`, so a check is
  proven against what enrolment actually writes), and a check context.
  """

  alias Kiln.Security.Check.Context
  alias KilnCMS.Accounts
  alias KilnCMS.TwoFactorFixtures

  @doc "A confirmed account with the global `role`, merged with `attrs`."
  def user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.User,
      Map.merge(
        %{
          email: "posture-#{role}-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(TwoFactorFixtures.password()),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        Map.new(attrs)
      )
    )
  end

  @doc "A membership of `user` on `org` at `role` (status `:active` unless `attrs` says). Returns `user`."
  def member!(user, org, role, attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.OrgMembership,
      Map.merge(%{organization_id: org.id, user_id: user.id, role: role}, Map.new(attrs))
    )

    user
  end

  @doc "Enrol `user` in TOTP as they would themselves. Returns the enrolled account."
  def enrol_totp!(user) do
    {:ok, staged} = Accounts.setup_totp(user, %{}, actor: user)

    {:ok, enrolled} =
      Accounts.confirm_totp(
        staged,
        %{code: TwoFactorFixtures.current_code(staged.totp_pending_secret)},
        actor: staged
      )

    enrolled
  end

  @doc "A check context for `org` (an org, an id or `nil`)."
  def context(org, opts \\ []) do
    %Context{
      org_id: org_id(org),
      build_env: Keyword.get(opts, :build_env, :test),
      now: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0),
      locale: Keyword.get(opts, :locale, "en")
    }
  end

  defp org_id(%{id: id}), do: id
  defp org_id(other), do: other
end
