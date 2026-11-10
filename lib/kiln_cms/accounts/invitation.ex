defmodule KilnCMS.Accounts.Invitation do
  @moduledoc """
  A pending invitation to a site, by email (#2135): an address, the site, the
  tier (and optional custom role) it will hold there, and the hash of the token
  mailed to it. See `KilnCMS.Accounts.Invitations` for why this is a row of its
  own rather than an account written up front, and for the token's rules.

  Global, not tenant-scoped, like `KilnCMS.Accounts.OrgMembership`: the accept
  page looks a token up whichever host it is opened on, and the Team page reads
  and acts on one org's rows by `organization_id` (`:for_org`).

  ## Who may do what

    * **Invite, resend, revoke, list** — platform admins only, as for
      memberships. A temporary platform admin cannot invite or resend
      (`Validations.StandingAdminOnly`): an accepted invitation outlasts the
      grant that sent it.
    * **Retire** — the invitations system actor only, when a membership
      change supersedes the invitation (#2452); recorded as
      `invitation_revoked`.
    * **Look a token up, accept, consume** — the system only. Forbidden to every
      authorized caller *before* the admin bypass, so not even an admin can
      call them with an actor; the accept paths call them with
      `authorize?: false` once the token is in hand.
    * **Prune** — the daily AshOban sweep.

  Nothing here is an API surface: no JSON:API, GraphQL or MCP exposure.
  """
  use Ash.Resource,
    otp_app: :kiln_cms,
    domain: KilnCMS.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  alias KilnCMS.Accounts.Invitations

  @pending_message "already has a pending invitation to this site"
  @prune_after_days Invitations.prune_after_days()

  @doc "The message the `(organization_id, email)` identity refuses a duplicate with."
  @spec pending_message() :: String.t()
  def pending_message, do: @pending_message

  postgres do
    table "invitations"
    repo KilnCMS.Repo

    references do
      # An invitation to a deleted site is meaningless.
      reference :organization, on_delete: :delete
      # A deleted custom role falls back to the tier alone, as on a membership.
      reference :custom_role, on_delete: :nilify
      # A deleted inviter leaves the invitation standing — except an `:admin`
      # one, which `Invitations.inviter_still_admin?/1` then refuses at accept.
      reference :invited_by, on_delete: :nilify
    end
  end

  # Rows past their expiry by more than `Invitations.prune_after_days/0` go.
  # Until then an expired row keeps its `(org, email)` slot, so inviting the
  # address again is a resend (a new token, the clock restarted) rather than a
  # second row, and a late click gets the same page as a made-up token.
  oban do
    triggers do
      trigger :prune_expired do
        action :prune_expired
        queue :default
        scheduler_cron "35 4 * * *"
        where expr(expires_at <= ago(^@prune_after_days, :day))

        worker_module_name KilnCMS.Accounts.Invitation.AshOban.Worker.PruneExpired
        scheduler_module_name KilnCMS.Accounts.Invitation.AshOban.Scheduler.PruneExpired
      end
    end
  end

  actions do
    defaults [:read]

    create :invite do
      description "Invite an address to a site at a tier (platform admins)."
      accept [:organization_id, :email, :role, :role_id]

      # A temporary admin's invitation would outlast its grant; a client-chosen
      # role_id must be this site's; the address must be one the mail queue
      # takes, so a typo is a form error rather than a crash.
      validate KilnCMS.Accounts.Validations.StandingAdminOnly
      validate KilnCMS.Accounts.Validations.RoleBelongsToOrg
      validate KilnCMS.Accounts.Validations.InvitationEmail

      change KilnCMS.Accounts.Changes.GenerateInvitationToken
      change KilnCMS.Accounts.Changes.SendInvitation

      # Audit log (#2241), in the transaction. No address in the metadata: the
      # target is the invitation row.
      change {KilnCMS.Security.Changes.Record,
              type: :member_invited,
              tenant: fn record, _changeset -> record.organization_id end,
              target: fn record, _changeset -> {"invitation", record.id} end,
              metadata: fn record, _changeset -> %{"role" => record.role, "resent" => false} end}

      metadata :token, :string do
        description "The plaintext token, returned once; only its hash is stored."
      end
    end

    # A new token (the old link stops working) and the clock restarted. Also
    # what inviting an address with an expired invitation does.
    update :resend do
      description "Send an invitation again with a new token (platform admins)."
      # The tier may be re-chosen: inviting an address whose invitation expired
      # resends it with what the admin picked this time.
      accept [:role, :role_id]
      require_atomic? false

      validate KilnCMS.Accounts.Validations.StandingAdminOnly
      validate KilnCMS.Accounts.Validations.RoleBelongsToOrg

      change KilnCMS.Accounts.Changes.GenerateInvitationToken
      change KilnCMS.Accounts.Changes.SendInvitation

      change {KilnCMS.Security.Changes.Record,
              type: :member_invited,
              tenant: fn record, _changeset -> record.organization_id end,
              target: fn record, _changeset -> {"invitation", record.id} end,
              metadata: fn record, _changeset -> %{"role" => record.role, "resent" => true} end}

      metadata :token, :string do
        description "The plaintext token, returned once; only its hash is stored."
      end
    end

    destroy :revoke do
      description "Withdraw a pending invitation; its link stops working (platform admins)."
      require_atomic? false

      change {KilnCMS.Security.Changes.Record,
              type: :invitation_revoked,
              tenant: fn record, _changeset -> record.organization_id end,
              target: fn record, _changeset -> {"invitation", record.id} end,
              metadata: fn record, _changeset -> %{"role" => record.role} end}
    end

    # An invitation a membership change has superseded (#2452): a platform
    # admin changed the tier or custom role of the person it names on its
    # site, or removed them, and `Changes.RetirePendingInvitation` retires it
    # in that write's transaction so the link cannot undo the decision.
    # System-only (as `SystemActor.new(:invitations)`). Recorded as the
    # revocation it is, with the admin who made the change as the actor when
    # the write carried one (`:retired_by` in the context).
    destroy :retire do
      description "Withdraw an invitation a membership change has superseded (system-only)."
      require_atomic? false

      change {KilnCMS.Security.Changes.Record,
              type: :invitation_revoked,
              tenant: fn record, _changeset -> record.organization_id end,
              target: fn record, _changeset -> {"invitation", record.id} end,
              user: fn _record, changeset ->
                case changeset.context[:retired_by] do
                  %KilnCMS.Accounts.User{} = user -> user
                  _system_or_none -> nil
                end
              end,
              metadata: fn record, _changeset -> %{"role" => record.role} end}
    end

    read :for_org do
      description "A site's invitations, live and expired (backs the Team page)."
      argument :organization_id, :uuid, allow_nil?: false
      filter expr(organization_id == ^arg(:organization_id))
      prepare build(sort: [inserted_at: :asc])
    end

    # The live invitation a token names. System-only (see the preparation).
    read :by_token do
      description "Find the live invitation a token names (system-only)."
      get? true
      argument :token, :string, allow_nil?: false, sensitive?: true
      prepare KilnCMS.Accounts.Preparations.InvitationByToken
    end

    # An invitation used up by its acceptance. No audit event of its own: the
    # membership it became records `role_granted`.
    destroy :consume do
      description "Remove an invitation that was accepted (system-only)."
    end

    # One click for a confirmed account: the membership, then the row gone.
    # Returns `%{outcome: :joined | :raised | :already_member, role: tier}`
    # (#2452): whether the account joined the site, was raised to the invited
    # tier, or already held it or a higher one, and the tier it now holds.
    action :accept_existing, :map do
      description "Accept an invitation with the confirmed account the address already has (system-only)."
      argument :token, :string, allow_nil?: false, sensitive?: true
      run KilnCMS.Accounts.Invitations.AcceptExisting
    end

    # The Team page's "Add or invite": an address with a confirmed account is
    # added straight away; any other is invited.
    action :add_or_invite, :map do
      description "Add an existing account to a site, or invite the address (platform admins)."
      argument :organization_id, :uuid, allow_nil?: false
      argument :email, :ci_string, allow_nil?: false
      argument :role, :atom, constraints: [one_of: [:admin, :editor, :viewer]], default: :viewer
      argument :role_id, :uuid
      run KilnCMS.Accounts.Invitations.AddOrInvite
    end

    destroy :prune_expired do
      description "Delete invitations long past their expiry (system sweep)."
      change filter(expr(expires_at <= ago(^@prune_after_days, :day)))
    end
  end

  policies do
    # The daily prune runs with no actor; AshOban's scheduler reads before its
    # worker destroys. Unconditional, as on `OrgMembership`, for that reason.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # System-only, and declared ABOVE the admin bypass on purpose: a bypass
    # that passes skips every policy after it, so below it an admin would be
    # admitted. Up here it binds everyone; the accept paths pass
    # `authorize?: false` once they hold the token. The preparation and the
    # accept implementation refuse an actor-carrying call as well.
    policy action([:by_token, :consume, :accept_existing]) do
      forbid_if always()
    end

    # System-only too, and above the admin bypass for the same reason: only
    # the invitations system actor may retire an invitation this way (an
    # admin withdraws one with `:revoke`). The grant is repeated in the last
    # policy, which every action meets.
    policy action(:retire) do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :invitations, action: :retire}
    end

    # Inviting is the same operator task as managing memberships.
    bypass KilnCMS.Accounts.Checks.PlatformAdmin do
      authorize_if always()
    end

    policy always() do
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :invitations, action: :retire}
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    # The site tier the membership will get. Least-privileged default.
    attribute :role, :atom do
      constraints one_of: [:admin, :editor, :viewer]
      default :viewer
      allow_nil? false
      public? true
    end

    # SHA-256 of the mailed token (`Invitations.hash/1`). Never the token.
    attribute :token_hash, :binary do
      allow_nil? false
      sensitive? true
      public? false
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_sent_at, :utc_datetime_usec do
      public? true
    end

    attribute :sent_count, :integer do
      default 0
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      allow_nil? false
      attribute_writable? true
    end

    # Named `custom_role` because `:role` is the tier atom, as on a membership.
    belongs_to :custom_role, KilnCMS.Accounts.Role do
      source_attribute :role_id
      attribute_writable? true
      public? false
    end

    # Set by `GenerateInvitationToken` from the acting admin, never from input.
    belongs_to :invited_by, KilnCMS.Accounts.User do
      attribute_writable? true
      public? false
    end
  end

  identities do
    # Single use and unguessable; the lookup is by this.
    identity :unique_token, [:token_hash]

    # One row per address per site, live or expired (a resend reuses it).
    identity :unique_pending, [:organization_id, :email], message: @pending_message
  end
end
