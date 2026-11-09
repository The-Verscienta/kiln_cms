defmodule KilnCMS.Accounts.OrgMembership do
  @moduledoc """
  A user's membership in an organization, carrying their **per-org** authoring
  role and read scope (epic #336).

  Users stay global (one account, usable across orgs); this join is where a
  user's effective role in a *given* org lives. The fields mirror the ones
  currently on `KilnCMS.Accounts.User` (`role`, `audiences`, `editable_types`)
  so a later PR can move the authorization source from the user onto the
  membership without another migration — for now they are populated (the
  backfill copies each user's `users.role` into their default-org membership)
  but the content policies still read the user's own `role` until that RBAC
  rewiring lands.

  The join itself is global (not tenant-scoped): it is queried by
  `organization_id`/`user_id` to build the org switcher and, later, to resolve a
  user's role for the request's tenant.
  """
  use Ash.Resource,
    otp_app: :kiln_cms,
    domain: KilnCMS.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  postgres do
    table "org_memberships"
    repo KilnCMS.Repo

    references do
      # A membership is meaningless without its org/user — clean up on delete.
      reference :organization, on_delete: :delete
      reference :user, on_delete: :delete
      # Deleting a custom role must not delete memberships — they fall back to
      # their own / the user's scope axes.
      reference :custom_role, on_delete: :nilify
    end

    # The unique identity is `(user_id, organization_id)` (user_id-leading), which
    # can't serve `organization_id`-only lookups — the `:for_org` read and the
    # org-delete cascade both probe by `organization_id` alone. Postgres doesn't
    # auto-index FK columns, so add one to avoid a sequential scan.
    custom_indexes do
      index [:organization_id]
      # The registration queue (#2251) lists one org's rows by status.
      index [:organization_id, :status]
    end
  end

  # Expired per-site temporary tiers, on the same hourly sweep and for the same
  # reasons as `KilnCMS.Accounts.User`'s — see that resource's trigger and
  # `KilnCMS.Accounts.RoleGrant`. Authorization never waits for it.
  oban do
    triggers do
      trigger :expire_role_grants do
        action :expire_role_grant
        queue :default
        scheduler_cron "10 * * * *"
        where expr(not is_nil(granted_role) and granted_role_expires_at <= now())

        worker_module_name KilnCMS.Accounts.OrgMembership.AshOban.Worker.ExpireRoleGrants
        scheduler_module_name KilnCMS.Accounts.OrgMembership.AshOban.Scheduler.ExpireRoleGrants
      end
    end
  end

  actions do
    defaults [:read]

    # Explicit so the audit event (#2241) rides the transaction: a membership is
    # a role granted on this site.
    create :create do
      primary? true
      change KilnCMS.Security.Changes.RecordRoleChange
    end

    # Explicit, so removing someone from an org drops the sockets that were
    # already authorized under it (#675). A membership is the per-org tier, so
    # deleting one narrows what its holder may do exactly as a demotion does.
    destroy :destroy do
      primary? true
      require_atomic? false

      change {KilnCMS.Accounts.Changes.EvictSessions,
              reason: :membership_removed, user_id: :user_id}

      # Audit log (#2241), in the transaction: the role the person no longer has.
      change KilnCMS.Security.Changes.RecordRoleChange
    end

    # Explicit (not a default) so the grant-shape validation — which inspects
    # the whole map and has no atomic expression — can run.
    update :update do
      primary? true
      require_atomic? false

      # A new standing tier at or above a live temporary one makes that grant
      # meaningless. Mirrors `User.:manage_access` — see the change module.
      change KilnCMS.Accounts.Changes.ClearRedundantRoleGrant

      # The per-org role, audiences and type scopes all live here, so an edit
      # narrows a live socket's grant the same way `manage_access` does (#675).
      change {KilnCMS.Accounts.Changes.EvictSessions,
              reason: :membership_changed, user_id: :user_id}

      # Audit log (#2241), in the transaction: a raised or lowered role (an edit
      # that leaves the role alone records nothing).
      change KilnCMS.Security.Changes.RecordRoleChange
    end

    # Time-boxed per-site elevation (`KilnCMS.Accounts.RoleGrant`) — the
    # membership twin of `User.:grant_temporary_role`, and its own action for the
    # same reason: it leaves the standing tier alone. Clearing both fields revokes
    # a grant early.
    update :grant_temporary_role do
      description "Grant or revoke a time-boxed elevation above the standing site tier."
      accept [:granted_role, :granted_role_expires_at]
      require_atomic? false
      validate KilnCMS.Accounts.Validations.TemporaryRoleGrant

      change {KilnCMS.Accounts.Changes.EvictSessions,
              reason: :role_grant_changed, user_id: :user_id}

      # Audit log (#2241), in the transaction: an elevation granted or revoked.
      change KilnCMS.Security.Changes.RecordElevation
    end

    # The expiry sweep's write (AshOban trigger above): clears the two dead
    # columns and drops sockets that authorized while the grant was live.
    update :expire_role_grant do
      description "Clear an expired temporary site tier (system sweep)."
      accept []
      require_atomic? false
      change set_attribute(:granted_role, nil)
      change set_attribute(:granted_role_expires_at, nil)

      change {KilnCMS.Accounts.Changes.EvictSessions,
              reason: :role_grant_expired, user_id: :user_id}
    end

    default_accept [
      :organization_id,
      :user_id,
      :role,
      :audiences,
      :editable_types,
      :readable_types,
      :field_grants,
      :field_read_grants,
      :role_id
    ]

    read :for_user do
      description "The orgs a user belongs to (backs the org switcher)."
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    # Active rows only (#2251): a registration awaiting approval, or a rejected
    # one kept, is not a member. The rosters built on this read (the Team page,
    # the mention roster, `CMS.ReadGrants.named?/3`) must not count it, and
    # `:registration_queue` below is where those rows are listed. `:for_user`
    # and `get_org_membership` stay unfiltered: affiliation needs every row.
    read :for_org do
      description "The members of an org (backs per-org RBAC administration)."
      argument :organization_id, :uuid, allow_nil?: false
      filter expr(organization_id == ^arg(:organization_id) and status == :active)
    end

    # ── registration approval (#2251) ──────────────────────────────────────
    #
    # A self-registration on a site that requires approval records a `:pending`
    # membership here; `KilnCMS.Accounts.Scoping` grants nothing through a row
    # that is not `:active`. `status` is in no `accept` list: these three
    # actions are the only writes that set it.

    # The registration's own write, from `Changes.QueueRegistration` inside the
    # user's create. System-only (see the policies): a person cannot queue
    # anyone, themselves included.
    create :queue_registration do
      description "Record a self-registration awaiting a site admin's approval (system-only)."
      accept [:organization_id, :user_id]
      change set_attribute(:status, :pending)
      change set_attribute(:role, :viewer)
      change set_attribute(:audiences, [])
      change KilnCMS.Security.Changes.RecordRegistration
    end

    # A site admin lets the applicant in: the row becomes an ordinary `:viewer`
    # membership, with the role and audiences it was queued with. A `:rejected`
    # row may be approved too, so a mistaken rejection is not final. Re-read and
    # locked first, so two admins deciding at once (or a stale page) cannot both
    # win: `DecideRegistration` refuses a row that is no longer `:pending`.
    update :approve_registration do
      description "Approve a registration awaiting a decision on this site."
      accept []
      require_atomic? false
      change get_and_lock_for_update()
      change {KilnCMS.Accounts.Changes.DecideRegistration, outcome: :approve}

      # After the commit, so the reconnect it causes is re-authorized against
      # the decided row, not the pending one still visible before COMMIT.
      change {KilnCMS.Accounts.Changes.EvictSessions,
              reason: :registration_approved, user_id: :user_id, after_commit?: true}

      # After the commit too: the applicant hears the decision (#2251).
      change {KilnCMS.Accounts.Changes.MailRegistrationDecision, outcome: :approve}

      change KilnCMS.Security.Changes.RecordRegistration
    end

    # A site admin turns the applicant away. The account and the row are kept
    # (`:rejected`), so the address cannot simply register here again; erasing
    # a rejected account is a later change. Allowed on an unconfirmed row too,
    # so a wave of bot sign-ups can be cleared without waiting for them.
    update :reject_registration do
      description "Reject a registration awaiting a decision on this site."
      accept []
      require_atomic? false
      change get_and_lock_for_update()
      change {KilnCMS.Accounts.Changes.DecideRegistration, outcome: :reject}

      # After the commit, so the reconnect it causes is re-authorized against
      # the decided row, not the pending one still visible before COMMIT.
      change {KilnCMS.Accounts.Changes.EvictSessions,
              reason: :registration_rejected, user_id: :user_id, after_commit?: true}

      # After the commit too: the applicant hears the decision (#2251).
      change {KilnCMS.Accounts.Changes.MailRegistrationDecision, outcome: :reject}

      change KilnCMS.Security.Changes.RecordRegistration
    end

    # The queue a site admin works through: one org's `:pending` rows, or its
    # `:rejected` ones. Admitted to an admin of the org the argument names (the
    # policies); `KilnCMS.Accounts.Registrations.queue/2` adds the applicant's
    # address to each row.
    read :registration_queue do
      description "One site's registrations awaiting a decision, or the rejected ones kept."
      argument :organization_id, :uuid, allow_nil?: false

      argument :status, :atom do
        constraints one_of: [:pending, :rejected]
        default :pending
        allow_nil? false
      end

      filter expr(organization_id == ^arg(:organization_id) and status == ^arg(:status))
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end
  end

  policies do
    # Managing memberships is a platform-operator task for now — admins only.
    # Except queueing a registration (#2251), which is the registration's own
    # system write and no person's: the bypass does not grant it, so the
    # system-only policy below decides it for an admin too.
    bypass KilnCMS.Accounts.Checks.PlatformAdmin do
      forbid_if action(:queue_registration)
      authorize_if always()
    end

    # The hourly `expire_role_grants` trigger runs with no actor. Unconditional —
    # not scoped to `action(:expire_role_grant)` — because AshOban's scheduler
    # first *reads* the rows to sweep, and a write-scoped grant never matched that
    # read: the self-only read policy below filtered it to nothing, so the sweep
    # silently never ran. Mirrors `KilnCMS.Accounts.Token`.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # Each policy below names its actions rather than an `action_type`, so the
    # registration actions (#2251) are decided by their own policies alone: Ash
    # ANDs every policy that applies, and the blanket write refusal or the
    # self-only read would otherwise refuse (or filter to nothing) a site admin
    # deciding a registration. An action no policy names is refused outright.

    # A user may read their own memberships (to populate their org switcher).
    policy action([:read, :for_user, :for_org]) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # Creating/changing/removing memberships is admin-only (the bypass above).
    policy action([:create, :update, :destroy, :grant_temporary_role, :expire_role_grant]) do
      forbid_if always()
    end

    # The registration's own write — system code only, from
    # `Changes.QueueRegistration`.
    policy action(:queue_registration) do
      authorize_if {KilnCMS.Checks.SystemActor,
                    subsystem: :registrations, action: :queue_registration}
    end

    # Listing and deciding registrations: an admin of the org the row (or, for
    # the queue, the argument) names — never the request's host, so another
    # site's admin is refused whichever host they ask from. A temporary platform
    # admin passes the bypass and is refused by `StandingAdminOnly` below.
    policy action([:registration_queue, :approve_registration, :reject_registration]) do
      authorize_if KilnCMS.Accounts.Checks.AdminOfMembershipOrg
    end
  end

  validations do
    # A malformed grant map must fail on the admin's write, not crash the
    # editor's next save (see the validation module).
    validate KilnCMS.Accounts.Validations.FieldGrantsShape, on: [:create, :update]

    validate {KilnCMS.Accounts.Validations.FieldGrantsShape, attribute: :field_read_grants},
      on: [:create, :update]

    validate KilnCMS.Accounts.Validations.ReadGrantsPrivate, on: [:create, :update]

    # A client-supplied role_id must reference a role of THIS org.
    validate KilnCMS.Accounts.Validations.RoleBelongsToOrg, on: [:create, :update]
    # A temporary platform admin must not confer a site tier — on anyone, itself
    # included — that would outlast the grant that let it act. Covers create,
    # `:update` and `:grant_temporary_role`; the actorless sweep and billing sync
    # pass. See the validation module.
    validate KilnCMS.Accounts.Validations.StandingAdminOnly, on: [:create, :update]
  end

  attributes do
    uuid_primary_key :id

    # The per-org authoring role (mirrors `User.role`). Least-privileged default.
    attribute :role, :atom do
      constraints one_of: [:admin, :editor, :viewer]
      default :viewer
      allow_nil? false
      public? true
    end

    # A time-boxed elevation above the standing tier above — the per-site twin of
    # `User.granted_role`. Same modelling and same reasons: `role` keeps the
    # standing tier, `KilnCMS.Accounts.Scoping.effective_tier/2` applies this one
    # while it is live, and expiry is a comparison rather than a scheduled write.
    # See KilnCMS.Accounts.RoleGrant.
    attribute :granted_role, :atom do
      constraints one_of: [:admin, :editor, :viewer]
      public? false
    end

    attribute :granted_role_expires_at, :utc_datetime_usec do
      public? false
    end

    # The per-org read axis (mirrors `User.audiences` — see KilnCMS.CMS.Audiences).
    attribute :audiences, {:array, :atom} do
      constraints items: [one_of: KilnCMS.CMS.Audiences.all()]
      default []
      allow_nil? false
      public? false
    end

    # The per-org authoring scope (mirrors `User.editable_types`, #332). Empty
    # means no restriction.
    attribute :editable_types, {:array, :string} do
      default []
      allow_nil? false
      public? false
    end

    # The per-org editorial read scope (mirrors `User.readable_types`, #332
    # phase 2). Empty means no restriction. A non-empty value here wins over
    # the user column for this org (see KilnCMS.Accounts.Scoping).
    attribute :readable_types, {:array, :string} do
      default []
      allow_nil? false
      public? false
    end

    # The per-org per-field write grants (mirrors `User.field_grants`, #332
    # slice 3). Empty means no restriction; a non-empty map wins wholesale
    # over the user column for this org (see KilnCMS.Accounts.Scoping).
    attribute :field_grants, :map do
      default %{}
      allow_nil? false
      public? false
    end

    # Per-custom-field READ restrictions (#2281): content-type name → the
    # private custom fields (`custom_fields.<name>`, or the bare
    # `custom_fields`) the editor may see. No entry for a type = unrestricted;
    # `[]` hides every private field. Resolved like `field_grants`
    # (KilnCMS.Accounts.Scoping.field_read_grant/3).
    attribute :field_read_grants, :map do
      default %{}
      allow_nil? false
      public? false
    end

    # Whether this row grants anything (#2251). `:active` is every membership
    # that predates registration approval and every one written since by any
    # path but a queued registration; `:pending` awaits a site admin; `:rejected`
    # was turned away and is kept. `KilnCMS.Accounts.Scoping` treats a row that is
    # not `:active` as no tier, no audiences and no scope on its site.
    attribute :status, :atom do
      constraints one_of: [:active, :pending, :rejected]
      default :active
      allow_nil? false
      public? true
    end

    # When a registration was approved or rejected; nil for every other row.
    attribute :decided_at, :utc_datetime_usec do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :user, KilnCMS.Accounts.User do
      allow_nil? false
      attribute_writable? true
    end

    # The optional custom role (#332 slice 4) — a named bundle of the three
    # grant axes. Named `custom_role` because `:role` is the capability-tier
    # atom attribute above; nil = no bundle (the built-in behavior).
    belongs_to :custom_role, KilnCMS.Accounts.Role do
      source_attribute :role_id
      attribute_writable? true
      public? false
    end
  end

  identities do
    # One membership row per (user, org).
    identity :unique_membership, [:user_id, :organization_id]
  end
end
