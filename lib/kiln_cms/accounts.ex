defmodule KilnCMS.Accounts do
  @moduledoc """
  The Accounts domain — authentication and identity (`User`, `Token`).

  Authentication is handled by AshAuthentication (password strategy). The
  `User.role` attribute (`:admin`/`:editor`/`:viewer`) drives RBAC across the
  CMS domain.
  """
  use Ash.Domain,
    otp_app: :kiln_cms

  resources do
    resource KilnCMS.Accounts.Token do
      # The actions on this resource that are ours rather than
      # AshAuthentication's — see `:spend_jti` (#743) and the hold pair (#742).
      # All three are `forbid_if always()`, so these names buy a caller nothing
      # without the `authorize?: false` only `KilnCMS.Accounts.PendingSignIn`
      # passes.
      define :spend_pending_sign_in, action: :spend_jti
      define :hold_first_factor_token, action: :hold_for_second_factor
      define :release_first_factor_token, action: :release_second_factor_hold

      # The by-purpose lookup those two need has no name here: `PendingSignIn`
      # finds the row through `AshAuthentication.TokenResource.Actions.get_token/3`,
      # which `KilnCMSWeb.BearerAuth` already uses for the same question.
      #
      # This one is different and does need a name, because `:get_token` filters
      # `expires_at > now()` and therefore cannot answer "is there a row for this
      # jti *at all*" — which is what tells a failed release apart from a
      # deployment that never stored the token in the first place. No policy
      # matches `:read` on this resource, so the name buys a caller nothing.
      define :get_stored_token_by_jti, action: :read, get_by: [:jti]
    end

    # External IdP links for OIDC SSO (#331) — managed by AshAuthentication.
    resource KilnCMS.Accounts.UserIdentity

    # WebAuthn credentials (#331 passkeys) — written only by the verified
    # ceremony (KilnCMS.Accounts.WebAuthn); self-managed from /editor/settings.
    resource KilnCMS.Accounts.Passkey do
      define :list_passkeys, action: :for_user, args: [:user_id]
      define :get_passkey, action: :read, get_by: [:id]
      define :get_passkey_by_credential_id, action: :read, get_by: [:credential_id]
      define :remove_passkey, action: :destroy
      # Ceremony-only writes (KilnCMS.Accounts.WebAuthn, `authorize?: false`
      # after Wax verification).
      define :register_passkey_credential, action: :register
      define :bump_passkey_usage, action: :bump_usage
    end

    # Web Push subscriptions (#628) — one row per browser per account.
    # `subscribe`/`for_users` are system calls: the first runs from the
    # controller after it has the actor, the second is the sender's read.
    resource KilnCMS.Accounts.PushSubscription do
      define :list_push_subscriptions, action: :for_user, args: [:user_id]
      define :get_push_subscription, action: :read, get_by: [:id]
      define :touch_push_subscription, action: :touch_delivered
      define :push_subscriptions_for, action: :for_users, args: [:user_ids]
      define :subscribe_to_push, action: :subscribe
      define :remove_push_subscription, action: :destroy
    end

    # The tenant registry (epic #336) + the user↔org membership join. The org is
    # not itself multitenant — it *is* the tenant list every scoped resource is
    # partitioned by.
    resource KilnCMS.Accounts.Organization do
      define :list_organizations, action: :read
      define :get_organization, action: :read, get_by: [:id]
      define :get_organization_by_slug, action: :by_slug, args: [:slug]
      define :get_organization_by_domain, action: :by_custom_domain, args: [:custom_domain]
      define :create_organization, action: :create
    end

    resource KilnCMS.Accounts.OrgMembership do
      define :list_org_memberships, action: :read
      define :list_memberships_for_user, action: :for_user, args: [:user_id]
      define :list_memberships_for_org, action: :for_org, args: [:organization_id]

      # The policy checks' membership lookup (KilnCMS.Accounts.Scoping): one
      # (user, org) row, read with `authorize?: false` by the checks themselves.
      define :get_org_membership, action: :read, get_by: [:user_id, :organization_id]
      define :update_org_membership, action: :update
      define :create_org_membership, action: :create
      define :remove_org_membership, action: :destroy
    end

    # Custom roles (#332 slice 4) — named bundles of the grant axes, assigned
    # to memberships via `role_id`. Admin-managed from /editor/team.
    resource KilnCMS.Accounts.Role do
      define :list_roles_for_org, action: :for_org, args: [:organization_id]
      define :get_role, action: :read, get_by: [:id]
      define :create_role, action: :create
      define :update_role, action: :update
      define :destroy_role, action: :destroy
    end

    # API keys for third-party / headless access (admin-managed). Pass
    # `actor: admin` — the resource policies restrict management to admins.
    # `access` defaults to :read; pass it in the params map for an authoring
    # (MCP/LLM) key: `mint_api_key(id, name, at, %{access: :read_write}, ...)`.
    # (Not a positional arg: an optional arg followed by the opts keyword list
    # is ambiguous at the call site.)
    resource KilnCMS.Accounts.ApiKey do
      define :mint_api_key, action: :create, args: [:user_id, :name, :expires_at]
      define :list_api_keys, action: :for_user, args: [:user_id]
      define :list_all_api_keys, action: :read
      define :get_api_key, action: :read, get_by: [:id]
      define :revoke_api_key, action: :revoke
    end

    resource KilnCMS.Accounts.User do
      define :list_users, action: :read
      define :get_user, action: :read, get_by: [:id]
      define :get_user_by_email, action: :get_by_email, args: [:email]
      define :update_notification_prefs, action: :update_notification_prefs
      # Two-factor (TOTP) self-service (issue #331) — pass `actor: user` (self).
      define :setup_totp, action: :setup_totp
      define :confirm_totp, action: :confirm_totp
      define :disable_totp, action: :disable_totp
      define :regenerate_totp_recovery_codes, action: :regenerate_totp_recovery_codes
      define :consume_totp_recovery_code, action: :consume_totp_recovery_code
      # Passkey sign-in completion (#331) — system-only (`authorize?: false`
      # from the ceremony after Wax verification; see the action + preparation).
      define :complete_passkey_sign_in, action: :sign_in_with_passkey, args: [:user_id]
      # Admin-only: assign role + consumer audiences; pass `actor: admin`.
      define :manage_user_access, action: :manage_access
      # System-only (`authorize?: false`) — called by KilnCMS.Billing.Entitlements,
      # the declarative recompute. An actor-carrying call is refused by the change
      # module, since the admin policy bypass would defeat a `forbid_if` alone.
      define :sync_billing_audiences, action: :sync_billing_audiences
      # GDPR Art. 17 erasure (#212) — admin-only; pass `actor: admin`.
      define :anonymize_user, action: :anonymize
    end
  end

  @doc """
  The id of the default organization (epic #336).

  The fixed sentinel every existing/tenant-less row belongs to: seeded by the
  backfill migration and stamped as the `org_id` default whenever a scoped
  resource is created without a tenant (non-strict `global?: true` rollout). A
  compile-time constant — no per-write database lookup.
  """
  @spec default_org_id() :: Ash.UUID.t()
  def default_org_id, do: KilnCMS.Accounts.Organization.default_id()

  @doc """
  The org id behind an `Organization` struct, a bare id, or `nil` (#527).

  Ash's `tenant:` accepts all three, so a request's org is passed around as any
  of them; the functions that take an id and not a tenant need it narrowed. Ten
  private copies of this had grown across the console and the core, and they
  disagreed on `nil` — some raised, some fell back to the sole org, one had no
  `is_binary` guard at all.

  `nil` resolves to `default_org_id/0`, the same fallback every tenant-less write
  already takes under the non-strict rollout, so a missing org reads as "no
  tenant" does everywhere else. Anything else raises: matching `%{id: id}`
  loosely — as several of the copies did — quietly accepts a `User`, a `Page`, or
  a socket and hands its id downstream as a tenant, where it surfaces not as an
  error but as an empty registry. Only these three shapes are an org.
  """
  @spec org_id(KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil) :: Ash.UUID.t()
  def org_id(%KilnCMS.Accounts.Organization{id: id}) when is_binary(id), do: id
  def org_id(id) when is_binary(id), do: id
  def org_id(nil), do: default_org_id()

  @doc """
  Every organization id (#419 strict-tenancy prep) — the tenant list for
  cross-org iteration: AshOban scheduler scans (`KilnCMS.Accounts.ListOrgIds`)
  and deliberate all-orgs sweeps (GDPR actor erasure). System-level read.
  """
  @spec list_org_ids() :: [Ash.UUID.t()]
  def list_org_ids do
    list_organizations!(authorize?: false, query: [select: [:id]])
    |> Enum.map(& &1.id)
  end

  @doc """
  The default organization struct (epic #336). Loaded by id; used as the tenant
  fallback when a request's host doesn't resolve to a specific org. Returns `nil`
  only if the seed row is missing (it's created by the backfill migration).
  """
  @spec default_org() :: KilnCMS.Accounts.Organization.t() | nil
  def default_org do
    case get_organization(default_org_id(), authorize?: false) do
      {:ok, org} -> org
      _ -> nil
    end
  end

  @doc "Whether the user has completed two-factor (TOTP) enrolment (issue #331)."
  @spec totp_enabled?(KilnCMS.Accounts.User.t()) :: boolean()
  def totp_enabled?(%KilnCMS.Accounts.User{totp_confirmed_at: at}), do: not is_nil(at)

  @doc """
  A JSON-serializable snapshot of a user's own data for an access/portability
  request (GDPR Art. 15/20, #212): profile fields and notification preferences.
  No secrets (password hash, tokens) are included.
  """
  @spec export_user_data(KilnCMS.Accounts.User.t()) :: map()
  def export_user_data(%KilnCMS.Accounts.User{} = user) do
    %{
      account: %{
        id: user.id,
        email: to_string(user.email),
        name: user.name,
        role: user.role,
        audiences: user.audiences,
        confirmed_at: user.confirmed_at,
        anonymized_at: user.anonymized_at
      },
      notification_preferences: %{
        notify_on_review_request: user.notify_on_review_request,
        notify_on_publish: user.notify_on_publish,
        notify_on_return_to_draft: user.notify_on_return_to_draft
      },
      # Paid memberships (#337 Phase 2). The provider ids ARE included: they are
      # identifiers a subprocessor holds about this person, so GDPR Art. 15/20
      # covers them, and having them lets the subject exercise their rights
      # against the provider directly. They are not credentials.
      memberships: membership_export(user)
    }
  end

  # A data-subject export is inherently cross-organization — the request arrives
  # on one host, but the person may hold memberships on several sites — so this
  # reads with `multitenancy :bypass` (the sanctioned exception) rather than the
  # request's tenant.
  defp membership_export(user) do
    case KilnCMS.Billing.memberships_for_export(user.id, authorize?: false) do
      {:ok, memberships} ->
        Enum.map(memberships, fn membership ->
          %{
            org_id: membership.org_id,
            tier_id: membership.tier_id,
            status: membership.status,
            current_period_end: membership.current_period_end,
            cancel_at_period_end: membership.cancel_at_period_end,
            activated_at: membership.activated_at,
            canceled_at: membership.canceled_at,
            provider_customer_id: membership.provider_customer_id,
            provider_subscription_id: membership.provider_subscription_id
          }
        end)

      _error ->
        []
    end
  end

  @doc """
  Resolve a plaintext `kiln_…` API key to its owning user (the Ash actor), or
  `:error`. Verifies the key exactly like the HTTP `ApiKeyAuth` plug — through
  the `:sign_in_with_api_key` strategy action — so the returned actor carries the
  `using_api_key?` metadata the content policies key off. Used off the request
  cycle by the visual-editing bridge socket (#355).
  """
  @spec actor_from_api_key(String.t()) :: {:ok, KilnCMS.Accounts.User.t()} | :error
  def actor_from_api_key(key) when is_binary(key) do
    KilnCMS.Accounts.User
    |> Ash.Query.for_read(:sign_in_with_api_key, %{api_key: key})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %KilnCMS.Accounts.User{} = user} -> {:ok, user}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def actor_from_api_key(_), do: :error
end
