defmodule KilnCMS.Billing do
  @moduledoc """
  Paid memberships (#337 Phase 2) — the billing loop that turns a
  self-registered `:viewer` into an entitled reader.

  A paid member is not a new identity model: it is a self-registered user whose
  active subscription grants one of the gated audiences from
  `KilnCMS.CMS.Audiences`. This domain owns the tiers on sale
  (`KilnCMS.Billing.MembershipTier`) and the provider credentials
  (`KilnCMS.Billing.Settings`); the payment provider owns money, dunning, tax and
  invoices, reached through the `KilnCMS.Billing.Provider` seam.

  ## Disabled until configured

  Nothing here activates on its own. `configured?/0` is false until an admin
  stores both secrets in `/editor/billing`, and every surface reads it: the join
  page renders no tiers, checkout 404s, and the webhook route 404s. That mirrors
  the posture of `KilnCMS.Seo.Generator` and `Kiln.Updates` — a fresh install
  makes no outbound calls and exposes no payment surface.

  ## Two scopes, deliberately

  Credentials are **instance-wide** (one provider account per instance — #337
  open question 1) and gate on the global `User.role`. Tiers are **per-site** and
  gate on `KilnCMS.CMS.Checks.OrgAdmin`. See both resources' moduledocs; mixing
  the two up is the hazard `KilnCMS.CMS.SiteBranding` documents.

  See `docs/memberships.md`.
  """
  use Ash.Domain

  require Ash.Query
  require Logger

  alias KilnCMS.Billing.Settings

  # The checkout path, the webhook receiver, the reconcile sweep and GDPR
  # erasure all reach billing with no actor of their own. `Settings` admits
  # this actor for `:read`/`:init`; `Membership` and `MembershipEvent` admit it
  # for the actions closed to every person (#1402).
  defp system_actor, do: KilnCMS.SystemActor.new(:billing)

  resources do
    resource KilnCMS.Billing.Settings do
      define :init_settings, action: :init
      define :list_settings, action: :read
      define :store_billing_secret, action: :store_secret, args: [:key, :value]

      define :configure_billing_key_source,
        action: :configure_key_source,
        args: [:key, :provider, {:optional, :config}]

      define :record_billing_verification, action: :record_verification
      define :clear_billing_credentials, action: :clear_credentials
    end

    resource KilnCMS.Billing.MembershipTier do
      define :create_tier, action: :create
      define :update_tier, action: :update
      define :destroy_tier, action: :destroy
      define :list_tiers, action: :read
      define :list_active_tiers, action: :active
      define :get_tier, action: :read, get_by: [:id]
      define :get_tier_by_slug, action: :read, get_by: [:slug]
      define :tier_by_price, action: :by_price, args: [:provider_price_id]
    end

    resource KilnCMS.Billing.Membership do
      define :start_membership, action: :start
      define :list_memberships, action: :read
      define :get_membership, action: :read, get_by: [:id]
      define :memberships_for_user, action: :for_user, args: [:user_id]
      # Cross-org, all statuses — GDPR export and erasure only.
      define :memberships_for_export, action: :all_for_user, args: [:user_id]
      define :entitling_memberships_for_user, action: :entitling_for_user, args: [:user_id]

      define :membership_by_subscription,
        action: :by_subscription,
        args: [:provider_subscription_id]

      define :memberships_by_customer, action: :by_customer, args: [:provider_customer_id]
      define :stale_memberships, action: :stale, args: [:before]
      # System-only (`authorize?: false`) — the webhook worker and reconcile sweep.
      define :apply_provider_state, action: :apply_provider_state
      # GDPR erasure — system-only (`authorize?: false`).
      define :anonymize_membership_row, action: :anonymize
      define :comp_membership, action: :comp
      define :uncomp_membership, action: :uncomp
    end

    resource KilnCMS.Billing.WebhookEvent do
      # All system-only: the receiver and worker run `authorize?: false`.
      define :receive_webhook_event, action: :receive
      define :claim_webhook_event, action: :claim
      define :mark_webhook_event_processed, action: :mark_processed
      define :mark_webhook_event_ignored, action: :mark_ignored
      define :mark_webhook_event_failed, action: :mark_failed
      define :get_webhook_event, action: :read, get_by: [:id]
      define :webhook_event_by_event_id, action: :by_event_id, args: [:provider_event_id]
      define :recent_webhook_events, action: :recent
      define :purgeable_webhook_events, action: :purgeable, args: [:before]
      define :destroy_webhook_event, action: :destroy
    end

    resource KilnCMS.Billing.MembershipEvent do
      define :append_membership_event, action: :append
      define :membership_events, action: :for_membership, args: [:membership_id]
      define :recent_membership_events, action: :recent
      define :anonymize_membership_event_actor, action: :anonymize_actor
    end
  end

  @doc """
  The settings singleton, or nil before first use. Read as the system actor
  (#1402): the platform-admin policy guards the UI path, while the checkout and
  webhook paths have no actor of their own.
  """
  @spec get_settings() :: Settings.t() | nil
  def get_settings do
    # The row is a singleton (unique `singleton` column), so a bare read returns
    # at most one record. `Settings` admits this actor for `:read` and `:init`
    # only — its write path stays platform-admin — and every secret column is
    # vault-encrypted and `sensitive?`; the struct never leaves the server. The
    # one web caller (`BillingLive`, via `ensure_settings!/0`) is itself
    # platform-admin-gated.
    case list_settings!(actor: system_actor()) do
      [settings | _rest] -> settings
      [] -> nil
    end
  end

  @doc """
  The settings singleton, created on first call.

  Called only from the admin console. Never from a read on a public path — that
  would turn page views into `INSERT`s, the hazard noted on
  `KilnCMS.CMS.SiteBranding`.
  """
  @spec ensure_settings!() :: Settings.t()
  def ensure_settings! do
    get_settings() || create_settings!()
  end

  defp create_settings! do
    # `ensure_settings!/0` takes no actor, so the system actor stands in — and
    # `Settings` admits it for `:init` by name (#1402). Its callers are
    # `BillingLive` (which mounts behind `platform_admin?`) and
    # `verify_credentials/1` (which pre-checks its actor against `Settings`'
    # policy before calling), and `:init` accepts no attributes — it inserts the
    # empty singleton row, which the identity makes a no-op on a race. Nothing
    # caller-supplied reaches it.
    init_settings!(%{}, actor: system_actor())
  rescue
    # Lost a concurrent-creation race on the singleton identity: the row exists
    # now, so read it.
    e in [Ash.Error.Invalid, Ash.Error.Unknown] ->
      get_settings() || reraise(e, __STACKTRACE__)
  end

  @doc """
  Both resolved provider secrets — the single resolution point.

  Returns `{:error, :not_configured}` before setup, or the underlying
  `KilnCMS.Keys` error (unset env var, unreadable file, failed decrypt) so the
  console can explain what to fix via `KilnCMS.Keys.describe_error/1`.
  """
  @spec credentials() :: {:ok, KilnCMS.Billing.Provider.config()} | {:error, term()}
  def credentials do
    with {:ok, secret_key} <- KilnCMS.Keys.fetch(:billing_secret_key),
         {:ok, webhook_secret} <- KilnCMS.Keys.fetch(:billing_webhook_secret) do
      {:ok, %{secret_key: secret_key, webhook_secret: webhook_secret}}
    end
  end

  @doc """
  Whether billing is usable: the settings row exists and both secrets resolve.

  Every payment surface gates on this, so an unconfigured instance never renders
  a dead checkout button or accepts a webhook.
  """
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _credentials}, credentials())

  @doc """
  Confirm the stored credentials work, and record which account they belong to.

  Backs the console's "Test connection" so a mistyped key fails at save time
  rather than at a member's first checkout.

  Takes the requesting actor. A caller `Settings`' policy refuses is turned
  away up front, before any side effect — no singleton row is created, no key
  decrypted, no provider dialed — as `{:error, :forbidden}` (#1309). The stamps
  themselves are still written through the policy with the same actor, so the
  policy stays the authority; a stamp that fails anyway (a DB error) comes back
  as `{:error, {:stamp_failed, error}}` on the success path and is logged on
  the failure path, where the provider's reason is the one the caller needs.
  """
  @spec verify_credentials(KilnCMS.Accounts.User.t()) :: {:ok, Settings.t()} | {:error, term()}
  def verify_credentials(actor) do
    if Ash.can?({Settings, :record_verification}, actor) do
      do_verify_credentials(actor)
    else
      {:error, :forbidden}
    end
  end

  defp do_verify_credentials(actor) do
    settings = ensure_settings!()

    with {:ok, config} <- credentials(),
         {:ok, account} <- provider().retrieve_account(config) do
      attrs = %{
        provider_account_id: account["id"],
        # Derived from the key prefix, not the response: the account object has
        # no reliable live/test flag, whereas the key itself is unambiguous.
        livemode: live_key?(config.secret_key),
        verification_error: nil
      }

      case record_billing_verification(settings, attrs, actor: actor) do
        {:ok, verified} -> {:ok, verified}
        {:error, error} -> {:error, {:stamp_failed, error}}
      end
    else
      {:error, reason} ->
        # The provider's reason is what the operator must see; a stamp that
        # fails on top of it (a DB error — authz was pre-checked above) would
        # otherwise vanish, so it goes to the log.
        case record_billing_verification(
               settings,
               %{verification_error: describe_error(reason)},
               actor: actor
             ) do
          {:ok, _stamped} ->
            :ok

          {:error, error} ->
            Logger.warning(
              "Billing verification failed AND the failure stamp was not saved: " <>
                inspect(error)
            )
        end

        {:error, reason}
    end
  end

  @doc """
  An operator-facing explanation of a credential or provider failure.

  Delegates key-resolution problems to `KilnCMS.Keys.describe_error/1` and adds
  the provider-transport cases, so the console never renders a raw tuple — or a
  provider error string, which can carry account details.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error({:http_status, 401, _body}),
    do: "The payment provider rejected these credentials (401). Check the secret key."

  def describe_error({:http_status, status, _body}),
    do: "The payment provider returned HTTP #{status}."

  def describe_error(reason) when reason in [:timeout, :closed],
    do: "The payment provider did not respond in time."

  def describe_error(:forbidden),
    do: "Your account may not record verification results. Sign in as a platform admin."

  def describe_error({:stamp_failed, _error}),
    do:
      "Connected to the payment provider, but the result could not be saved. Check the server logs."

  def describe_error(%{__exception__: true} = error),
    do: "Could not reach the payment provider: #{Exception.message(error)}"

  def describe_error(reason), do: KilnCMS.Keys.describe_error(reason)

  # A live secret key is `sk_live_…` (or `rk_live_…` for a restricted key). Any
  # other prefix — including a test key — is treated as not-live, so the console
  # never claims live mode it can't prove. `credentials/0` resolves through
  # `KilnCMS.Keys.fetch/1`, which yields a binary or an error tuple, so the
  # guard is the whole contract — there is no non-binary case to fall back to.
  defp live_key?(secret_key) when is_binary(secret_key),
    do: String.contains?(secret_key, "_live_")

  @doc """
  Terminate a membership for GDPR erasure, re-scoped to its own organization.

  Local only — see `KilnCMS.Accounts.Changes.AnonymizeUser` for why this does not
  cancel at the payment provider.
  """
  @spec anonymize_membership(struct()) :: :ok
  def anonymize_membership(membership) do
    # `Membership`'s policy closes `:anonymize` to every PERSON, admin
    # included (`forbid_if always()`), and admits the system actor by name
    # (#1402). The caller is `Accounts.Changes.AnonymizeUser` — an
    # admin-policied erasure with no actor to hand down. `accept []`, tenant
    # re-scoped to the row's own org.
    anonymize_membership_row(membership, actor: system_actor(), tenant: membership.org_id)
    :ok
  end

  @doc """
  Clear the acting admin from every membership event they caused (GDPR erasure).

  The events themselves survive as a pseudonymous entitlement trail — the same
  retention decision `KilnCMS.History.anonymize_actor/1` makes for document
  events (#219). Cross-org, so it sweeps each organization in turn.
  """
  @spec anonymize_actor(Ash.UUID.t()) :: :ok
  def anonymize_actor(user_id) do
    # The read and the bulk update both run as the system actor (#1402):
    # `MembershipEvent` is append-only to every PERSON (`forbid_if always()` on
    # create/update) and admits this actor by name, and the caller is
    # `Accounts.Changes.AnonymizeUser` (`User.:anonymize`, admin-policied) with
    # no actor in hand. `user_id` is the row being erased, not input; the filter
    # carries the grant, `accept []`, and each org's sweep is scoped to its own
    # tenant.
    Enum.each(KilnCMS.Accounts.list_org_ids(), fn org_id ->
      KilnCMS.Billing.MembershipEvent
      |> Ash.Query.for_read(:read, %{}, actor: system_actor(), tenant: org_id)
      |> Ash.Query.filter(actor_id == ^user_id)
      |> Ash.bulk_update(:anonymize_actor, %{},
        # Same actor as the read above.
        actor: system_actor(),
        tenant: org_id,
        return_errors?: false
      )
    end)

    :ok
  end

  @doc "The configured `KilnCMS.Billing.Provider` implementation."
  @spec provider() :: module()
  def provider, do: config(:provider, KilnCMS.Billing.Providers.Stripe)

  @doc false
  # Extra Req options (e.g. a `Req.Test` plug in the test env).
  def req_options, do: config(:req_options, [])

  defp config(key, default),
    do: Keyword.get(Application.get_env(:kiln_cms, __MODULE__, []), key, default)
end
