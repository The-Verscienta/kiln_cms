defmodule KilnCMS.CMS.SiteSecondFactorPolicy do
  @moduledoc """
  Whether this site requires two-step sign-in, from whom, and after how long
  (#2247).

    * `required_for` — `:off` (the default, and a site with no row),
      `:admins`, `:editors` (editors and administrators) or `:everyone`
      (administrators, editors and viewers).
    * `grace_days` — how long a covered account has to set up a second factor,
      0 to 90 days (default 14).

  `KilnCMS.Accounts.TwoFactorRequirement` reads it and decides each account's
  status. An account's grace runs from the latest of when the account was
  created, when its membership on this site was created, and when its tier
  became covered here; promotions do not restart it.

  Five columns are not accepted from input. `KilnCMS.CMS.Changes.StampSecondFactorRequirement`
  writes them on every save:

    * `admin_required_since`, `editor_required_since`, `viewer_required_since`
      — when each tier became covered. A stamp is kept while its tier stays
      covered, so lengthening the grace or moving from `:admins` to
      `:editors` does not restart the administrators' clock, and is cleared
      when the tier stops being covered.
    * `policy_changed_at` — when the row last changed.

  ## Writing it

  Every person's `:save` and `:update` needs that person to hold a second
  factor **and** to prove it now: a session that verified one in the last 15
  minutes, or a code from their authenticator app
  (`KilnCMS.CMS.Changes.SaverVerifiedSecondFactor`). Turning the requirement
  off is a save of `required_for: :off`, so off has one path and one audit
  trail; `:destroy` is refused to everyone. Each person's write records
  `second_factor_policy_changed`.

  ## The operator's override

  `operator_override` sets `required_for` to `:off` and nothing else: the way
  back in when no administrator of the site can pass the requirement (a last
  administrator whose only passkey is lost). Only the `:operator` system
  actor may run it (`KilnCMS.Release.second_factor_requirement_off/1`); an
  admin is refused. It records `second_factor_policy_changed` with `via:
  "console"` and no actor.

  Not an API surface: absent from JSON:API, GraphQL and MCP.
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_second_factor_policy",
    accept: [:required_for, :grace_days],
    upsert_fields: [
      :required_for,
      :grace_days,
      :admin_required_since,
      :editor_required_since,
      :viewer_required_since,
      :policy_changed_at
    ],
    save_arguments: [{:code, :string, sensitive?: true, allow_nil?: true}],
    save_changes: [KilnCMS.CMS.Changes.StampSecondFactorRequirement],
    read: :admin,
    audit: {:change, KilnCMS.CMS.Changes.RecordSecondFactorPolicyChange},
    admin_columns: [:required_for, :grace_days, :updated_at],
    system_actions: [read: [:accounts, :operator], operator_override: :operator]

  @tiers [:admin, :editor, :viewer]
  @max_grace_days 90

  @doc "The tiers a policy can cover, strongest first."
  @spec tiers() :: [:admin | :editor | :viewer]
  def tiers, do: @tiers

  @doc "The longest accepted grace period, in days."
  @spec max_grace_days() :: pos_integer()
  def max_grace_days, do: @max_grace_days

  @doc """
  The tiers `required_for` covers: `:admins` the administrators, `:editors`
  editors and administrators, `:everyone` all three.
  """
  @spec covered_tiers(atom()) :: [:admin | :editor | :viewer]
  def covered_tiers(:admins), do: [:admin]
  def covered_tiers(:editors), do: [:admin, :editor]
  def covered_tiers(:everyone), do: @tiers
  def covered_tiers(_off), do: []

  actions do
    update :operator_override do
      description "Turn the requirement off from the server (KilnCMS.Release.second_factor_requirement_off/1)."
      accept []
      require_atomic? false

      # Re-read and lock the row in the transaction, so the stamps and the
      # audit event describe what was stored when the override ran.
      change get_and_lock_for_update()
      change set_attribute(:required_for, :off)
      change KilnCMS.CMS.Changes.StampSecondFactorRequirement
      change KilnCMS.CMS.Changes.RecordSecondFactorPolicyChange
    end
  end

  changes do
    # The person writing must hold a second factor and have proved it now.
    # On both person-facing writes: the macro emits `:update` next to `:save`,
    # and a guard on one of them only is a guard with a side door.
    # `operator_override` is the operator's, refused to every person by policy.
    change KilnCMS.CMS.Changes.SaverVerifiedSecondFactor,
      on: [:create, :update],
      where: [action_is([:save, :update])]

    # Bust the cached policy on every node and tell the site's open pages, once
    # the write commits.
    change KilnCMS.CMS.Changes.SecondFactorPolicyChanged, on: [:create, :update]
  end

  policies do
    # The way back in from the server, and nothing else. ANDed with the
    # OrgSettings write policy, which admits an org admin for any update: this
    # one refuses everyone but the operator.
    policy action(:operator_override) do
      authorize_if {KilnCMS.Checks.SystemActor,
                    subsystem: [:operator], action: [:operator_override]}
    end

    # Off is `save(required_for: :off)`: one path, one audit trail.
    policy action(:destroy) do
      forbid_if always()
    end
  end

  attributes do
    attribute :required_for, :atom do
      allow_nil? false
      default :off
      public? true
      constraints one_of: [:off, :admins, :editors, :everyone]
    end

    # `:save` is an upsert, and a defaulted column is always carried on its
    # create side: a save that leaves this out resets it to 14. Every writer
    # passes both settings.
    attribute :grace_days, :integer do
      allow_nil? false
      default 14
      public? true
      constraints min: 0, max: @max_grace_days
    end

    attribute :admin_required_since, :utc_datetime_usec do
      public? true
      writable? true
    end

    attribute :editor_required_since, :utc_datetime_usec do
      public? true
      writable? true
    end

    attribute :viewer_required_since, :utc_datetime_usec do
      public? true
      writable? true
    end

    attribute :policy_changed_at, :utc_datetime_usec do
      public? true
      writable? true
    end
  end
end
