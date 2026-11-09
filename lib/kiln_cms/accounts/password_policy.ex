defmodule KilnCMS.Accounts.PasswordPolicy do
  @moduledoc """
  What the breached-password check does for one password being set (#2240):
  `:off`, `:warn` or `:block`.

  ## The ladder

  The request org's `KilnCMS.CMS.SitePasswordPolicy` row, then the operator's
  default (`BREACHED_PASSWORD_POLICY`, `KilnCMS.Accounts.BreachedPassword`),
  then `:warn`. With the deployment switch off (`BREACHED_PASSWORD_CHECK=false`)
  the answer is `:off` whatever any row says.

  `:block` only ever applies to an account whose tier is `:admin`; for an
  editor or a viewer it reads as `:warn`. The tier is the **target** account's
  (the one whose password is being set), never the actor's: a reset is done by
  the owner of an account an attacker may already hold, and a registration has
  no actor.

  ## The target's tier

  `target_tier/2` is the stricter of the account's standing or granted tier
  (`KilnCMS.Accounts.RoleGrant.effective_role/1`) and its tier on the request's
  org (`KilnCMS.Accounts.Scoping.effective_tier/2`), so an account that is a
  viewer globally but an admin of this org by membership gets `:block`.
  Residual gap: the policy of the *request's* org is evaluated against the
  tier the account holds; an account that is an admin of some *other* org is
  not blocked here (`docs/threat-model.md`).

  ## Failing open

  The row is read as `KilnCMS.OrgSettings.system(:accounts)` with
  `authorize_with: :error`, so a refused read is an error and not "no row". An
  unreadable row (refusal, missing table mid-deploy, pool timeout) is logged
  and answered `:warn`: neither silently off nor blocking. The row is read
  here, on the caller's process and outside any spawned task, so the test
  sandbox's ownership holds. Not cached: a changed setting applies to the next
  password.
  """

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.BreachedPassword
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Accounts.Scoping

  @type policy :: :off | :warn | :block
  @type tier :: :admin | :editor | :viewer | :none

  @tiers [:none, :viewer, :editor, :admin]

  @doc """
  The policy for setting a password on an account of `target_tier` in `org`
  (an org id, an `Organization`, or `nil` for the default org).
  """
  @spec resolve(Accounts.Organization.t() | Ash.UUID.t() | nil, tier() | atom()) :: policy()
  def resolve(org, target_tier) do
    case read(org, target_tier) do
      {:ok, policy} -> policy
      :error -> :warn
    end
  end

  @doc """
  `resolve/2`, telling an unreadable row (`:error`) apart from the `:warn`
  `resolve/2` answers for it. For the Security posture page (#2252), which
  must not report a setting it cannot see.
  """
  @spec read(Accounts.Organization.t() | Ash.UUID.t() | nil, tier() | atom()) ::
          {:ok, policy()} | :error
  def read(org, target_tier) do
    if BreachedPassword.enabled?() do
      with {:ok, policy} <- org |> Accounts.org_id() |> configured() do
        {:ok, downgrade(policy, target_tier)}
      end
    else
      {:ok, :off}
    end
  end

  @doc """
  The stricter of `user`'s own (possibly temporary) role and its tier on `org`.
  `nil` — an account that does not exist yet — is a `:viewer`, which is what
  self-registration creates.
  """
  @spec target_tier(map() | nil, Accounts.Organization.t() | Ash.UUID.t() | nil) :: tier()
  def target_tier(nil, _org), do: :viewer

  def target_tier(%{} = user, org) do
    own = normalize(RoleGrant.effective_role(user))
    on_org = normalize(Scoping.effective_tier(user, Accounts.org_id(org)))
    Enum.max_by([own, on_org], &Enum.find_index(@tiers, fn tier -> tier == &1 end))
  end

  defp normalize(tier) when tier in @tiers, do: tier
  defp normalize(_other), do: :none

  defp downgrade(:block, :admin), do: :block
  defp downgrade(:block, _tier), do: :warn
  defp downgrade(policy, _tier), do: policy

  defp configured(org_id) do
    actor = KilnCMS.OrgSettings.system(:accounts)

    resolved =
      KilnCMS.OrgSettings.resolve_uncached(org_id,
        read:
          &KilnCMS.CMS.list_site_password_policy(
            tenant: &1,
            actor: actor,
            authorize_with: :error
          ),
        # `nil` is reserved for "could not read", so "no row" is its own value.
        build: fn
          nil -> {:operator, BreachedPassword.default_policy()}
          row -> {:site, row.breached_password_policy}
        end,
        label: "breached password policy"
      )

    case resolved do
      {_source, policy} -> {:ok, policy}
      nil -> :error
    end
  end
end
