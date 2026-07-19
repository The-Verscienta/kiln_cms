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
    resource KilnCMS.Accounts.Token

    # External IdP links for OIDC SSO (#331) — managed by AshAuthentication.
    resource KilnCMS.Accounts.UserIdentity

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
      define :create_org_membership, action: :create
      define :remove_org_membership, action: :destroy
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
      # Admin-only: assign role + consumer audiences; pass `actor: admin`.
      define :manage_user_access, action: :manage_access
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
      }
    }
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
