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

      # The invitation still pending for this person here goes too (#2452):
      # left behind, its link would put back a membership just removed.
      # First, so the invitation's row is locked before the membership's.
      change KilnCMS.Accounts.Changes.RetirePendingInvitation

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

      # A changed tier or custom role retires the invitation still pending for
      # this person here (#2452), so an older link cannot raise them back over
      # the decision just made. First, so the invitation's row is locked before
      # the membership's (the accept path's order).
      change KilnCMS.Accounts.Changes.RetirePendingInvitation

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
    # that is not `:active`. `status` is in no `accept` list: the registration
    # actions below are the only writes that set it.

    # The registration's own write, from `Changes.QueueRegistration` inside the
    # user's create, or from `SiteSso.Admission` for an account a site's own
    # single sign-on provisions (#2514). System-only (see the policies): a person cannot queue
    # anyone, themselves included.
    create :queue_registration do
      description "Record a self-registration awaiting a site admin's approval (system-only)."
      accept [:organization_id, :user_id]

      # Whether the registration created the account (#2514): a password
      # sign-up always does, a site's own single sign-on does for an address
      # it provisions. Recorded on the row as `created_account`.
      argument :new_account?, :boolean, default: false, allow_nil?: false

      # How the account registered, for the audit event.
      argument :method, :atom do
        constraints one_of: [:password, :site_sso]
        default :password
        allow_nil? false
      end

      change set_attribute(:status, :pending)
      change set_attribute(:role, :viewer)
      change set_attribute(:audiences, [])
      change set_attribute(:created_account, arg(:new_account?))
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

      # The account's row before the membership's (#2514, `AccountLock`'s lock
      # order); an erased applicant is `DecideRegistration`'s to refuse.
      change {KilnCMS.Accounts.Changes.LockAccount, refuse_erased?: false}
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

    # An invitation honoured over a registration on its site (#2514): the
    # invitee accepted (`Invitations.grant_membership/4`, as
    # `SystemActor.new(:invitations)`), or a platform admin added a confirmed
    # address directly (`Invitations.AddOrInvite`, `via: :added`). The row
    # becomes `:active` with the tier the invitation names, rather than
    # being left waiting behind a membership that never arrives.
    #
    # `DecideRegistration` refuses as for `:approve_registration` (a row no
    # longer waiting, an unconfirmed or an erased applicant) and one more
    # case: a `:rejected` row is approved only when the invitation was sent
    # after the rejection (`invited_at` later than `decided_at`). An older
    # invitation was sent before a site admin turned the applicant away, so it
    # does not overrule that decision.
    #
    # No decision mail: the invitee accepted, or is told they were added.
    update :approve_registration_by_invitation do
      description "Approve a registration because an invitation to its site was honoured (system-only)."
      accept []
      require_atomic? false

      argument :role, :atom do
        constraints one_of: [:admin, :editor, :viewer]
        default :viewer
        allow_nil? false
      end

      argument :role_id, :uuid

      # When the invitation was last sent (or, for a direct add, now).
      argument :invited_at, :utc_datetime_usec, allow_nil?: false

      # How the invitation arrived, for the audit event.
      argument :via, :atom do
        constraints one_of: [:invitation, :added]
        default :invitation
        allow_nil? false
      end

      # The role_id the row will take is the argument, not the row's own
      # (validations run before the hook that writes it).
      validate {KilnCMS.Accounts.Validations.RoleBelongsToOrg, argument: :role_id}

      # The account's row before the membership's, as `:approve_registration`.
      change {KilnCMS.Accounts.Changes.LockAccount, refuse_erased?: false}
      change get_and_lock_for_update()
      change {KilnCMS.Accounts.Changes.DecideRegistration, outcome: :approve_by_invitation}

      # After the commit, so the reconnect it causes is re-authorized against
      # the decided row, not the pending one still visible before COMMIT.
      change {KilnCMS.Accounts.Changes.EvictSessions,
              reason: :registration_approved, user_id: :user_id, after_commit?: true}

      change KilnCMS.Security.Changes.RecordRegistration
    end

    # An invitation accepted by someone already on its site (#2452,
    # `Invitations.grant_membership/4`, as `SystemActor.new(:invitations)`):
    # the membership takes the invited tier when that is higher than its
    # standing one, and is never lowered. `RaiseRoleByInvitation` judges the
    # row as locked here, not as the caller read it, and refuses an equal or
    # lower tier (`:not_higher`) before anything is written, and a row that is
    # not `:active`. The other axes (audiences, type scopes, field grants) are
    # kept; `role_id` becomes the invitation's custom role when it names one.
    #
    # Not `:update`: that accepts every grant axis and retires the pending
    # invitation (`RetirePendingInvitation`), which this write consumes itself.
    update :raise_role_by_invitation do
      description "Raise an active membership to the tier an accepted invitation names (system-only)."
      accept []
      require_atomic? false

      argument :role, :atom do
        constraints one_of: [:admin, :editor, :viewer]
        allow_nil? false
      end

      argument :role_id, :uuid

      # The role_id the row may take is the argument, not the row's own
      # (validations run before the hook that writes it).
      validate {KilnCMS.Accounts.Validations.RoleBelongsToOrg, argument: :role_id}

      # The account's row before the membership's (`AccountLock`'s lock order).
      change KilnCMS.Accounts.Changes.LockAccount
      change get_and_lock_for_update()
      change KilnCMS.Accounts.Changes.RaiseRoleByInvitation

      # After the commit, so the reconnect it causes is authorized against the
      # raised row, not the old one still visible before COMMIT.
      change {KilnCMS.Accounts.Changes.EvictSessions,
              reason: :membership_changed, user_id: :user_id, after_commit?: true}

      # Audit log (#2241), in the transaction: `role_granted`, with the
      # previous role.
      change KilnCMS.Security.Changes.RecordRoleChange
    end

    # A site admin turns the applicant away. The row is kept (`:rejected`), and
    # so is the account, so the address cannot simply register here again.
    # Allowed on an unconfirmed row too, so a wave of bot sign-ups can be
    # cleared without waiting for them.
    #
    # Unless the site erases unconfirmed rejected accounts (#2514,
    # `SiteRegistration.rejected_accounts`) and the caller asks for it
    # (`erase: true`, which the console passes only when its confirmation said
    # so): then `EraseRejectedAccount` erases the account in this transaction,
    # when its address was never confirmed and nothing but this application
    # hangs off it (`Registrations.Erasure`). Declared first, so the account's
    # row is locked before the membership's.
    update :reject_registration do
      description "Reject a registration awaiting a decision on this site."
      accept []
      require_atomic? false

      argument :erase, :boolean do
        description "Erase the account too, when the site's setting and the account allow it."
        default false
        allow_nil? false
      end

      change KilnCMS.Accounts.Changes.EraseRejectedAccount
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
    # `Changes.QueueRegistration` and `SiteSso.Admission`.
    policy action(:queue_registration) do
      authorize_if {KilnCMS.Checks.SystemActor,
                    subsystem: :registrations, action: :queue_registration}
    end

    # Honouring an invitation over a registration (#2514) — system code only,
    # from `Invitations.grant_membership/4`. A platform admin's direct add
    # passes the bypass above (a temporary one is refused by
    # `StandingAdminOnly`); a site admin decides registrations under
    # Registrations instead.
    policy action(:approve_registration_by_invitation) do
      authorize_if {KilnCMS.Checks.SystemActor,
                    subsystem: :invitations, action: :approve_registration_by_invitation}
    end

    # Raising a membership to an accepted invitation's tier (#2452) — system
    # code only, from `Invitations.grant_membership/4`. A platform admin passes
    # the bypass above, as for every membership write; `:update` already lets
    # them set any tier.
    policy action(:raise_role_by_invitation) do
      authorize_if {KilnCMS.Checks.SystemActor,
                    subsystem: :invitations, action: :raise_role_by_invitation}
    end

    # Listing and deciding registrations: an admin of the org the row (or, for
    # the queue, the argument) names — never the request's host, so another
    # site's admin is refused whichever host they ask from. A temporary platform
    # admin passes the bypass and is refused by `StandingAdminOnly` below.
    policy action([:registration_queue, :approve_registration, :reject_registration]) do
      authorize_if KilnCMS.Accounts.Checks.AdminOfMembershipOrg
    end
  end

  changes do
    # Every membership create takes the account's row first (#2514): an
    # erasure of a rejected registration then cannot miss a membership being
    # created elsewhere, and a create reaching an erased account is refused.
    # Resource-wide, so a create path added later cannot forget it.
    change KilnCMS.Accounts.Changes.LockAccount, on: [:create]
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

    # Whether this row's registration created the account (#2514): true for a
    # password sign-up queued here and for an account a site's own single
    # sign-on provisioned into the queue; false for every other row, including
    # every row written before the column existed.
    attribute :created_account, :boolean do
      default false
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
