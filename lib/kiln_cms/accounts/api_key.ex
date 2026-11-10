defmodule KilnCMS.Accounts.ApiKey do
  @moduledoc """
  A hashed, revocable API key bound to a `User`, for third-party / headless
  access to the delivery API and the MCP authoring endpoint.

  A key authenticates as its owning user, so it inherits that user's read scope
  (role + audiences). What it may *do* with that identity is bounded by its
  `access` scope:

    * `:read` (the default) — delivery reads only. The JSON:API and GraphQL
      surfaces do route writes since #330 (reversing decision D7), and the
      content policy forbids every one of them to a read-scoped key, so a
      leaked key can never write regardless of the owner's role.
    * `:read_write` — may also author content (create/update, including
      workflow transitions) as its owning user, within that user's role. Built
      for LLM / automation clients on the `/mcp` endpoint (see `docs/mcp.md`).
      Hard deletes stay forbidden for every key, whatever its scope.
    * `:draft_write` — for a headless consumer's service (#2273): may create
      drafts and edit **its own** drafts, and nothing else — no publishing,
      submitting for review, deleting, media, or touching a document that is
      live or someone else's. The bound is a policy on `Content`
      (`KilnCMS.Accounts.Checks.DraftWriteKey`) that does not consult the
      owner's role. Mint it on a viewer-tier service account with a lifetime
      under `:draft_write_key_max_ttl_days` (default 30); both are enforced
      here (`Validations.DraftWriteKey`).

  ## Self-rotation (`:draft_write` only)

  An admin may set `rotatable_until` when minting a `:draft_write` key (at most
  `:draft_write_key_max_rotation_days`, default 365, from mint). Until that date
  the key may exchange itself for a fresh one through the `:rotate` action
  (`POST /api/keys/rotate`): same owner, same scope, same name and same
  `rotatable_until`, with `expires_at = min(now + max TTL, rotatable_until)`.
  The presenting key is revoked in the same transaction, under a row lock, so a
  lineage has at most one live key, and no chain outlives the date the admin
  chose. The action takes no input: there is nothing for the caller to widen.
  See `KilnCMS.Accounts.Changes.RotateDraftWriteKey` and ADR 0012.

  For a pure public-content integrator, mint a `:read` key on a dedicated
  `:viewer` account. For an LLM author, mint a `:read_write` key on an
  `:editor` account — its drafts still go through admin review to publish.

  Only the SHA-256 hash of the key is stored; the plaintext is returned **once**
  at creation, in `key.__metadata__.plaintext_api_key`. Keys look like
  `kiln_<base62>_<crc>` — the `kiln_` prefix lets the auth plug tell them apart
  from JWT bearer tokens (and enables GitHub-style secret-scanning revocation).
  """
  use Ash.Resource,
    otp_app: :kiln_cms,
    domain: KilnCMS.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # Secret-scanning-friendly prefix baked into every generated key. Kept in sync
  # with the auth plug (KilnCMSWeb.Plugs.ApiKeyAuth) that routes on it.
  @prefix "kiln"
  def prefix, do: @prefix

  postgres do
    table "api_keys"
    repo KilnCMS.Repo

    references do
      # Lineage is history, not a dependency: deleting an old key must not take
      # its successor with it.
      reference :rotated_from, on_delete: :nilify
    end

    custom_indexes do
      # The successor lookup (reuse detection, the admin list's lineage) and
      # the live-keys-of-a-lineage read that reuse detection revokes.
      index [:rotated_from_id]
      index [:lineage_id]
    end
  end

  actions do
    defaults [:read, :destroy]

    read :for_user do
      description "All keys minted for a user, newest first (admin key management)."
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
      prepare build(sort: [created_at: :desc])
    end

    create :create do
      primary? true
      description "Mint an API key. The plaintext is returned once in metadata."
      accept [:user_id, :name, :expires_at, :access, :rotatable_until]

      validate KilnCMS.Accounts.Validations.DraftWriteKey

      # The owner's row first, refusing an erased account (#2514). The foreign
      # key alone would wait for an erasure of a rejected registration and then
      # mint a key for the tombstone.
      change KilnCMS.Accounts.Changes.LockAccount

      change {AshAuthentication.Strategy.ApiKey.GenerateApiKey,
              prefix: @prefix, hash: :api_key_hash}

      # Audit log (#2241), in the transaction. The name and scope only, never the
      # key or its hash.
      change {KilnCMS.Security.Changes.Record,
              type: :api_key_created,
              target: fn record, _changeset -> {"api_key", record.id} end,
              metadata: fn record, _changeset ->
                %{"name" => record.name, "scope" => record.access}
              end}
    end

    create :rotate do
      description """
      Exchange the presenting `:draft_write` key for a fresh one (same owner,
      scope, name and rotation ceiling) and revoke the presenting key in the same
      transaction. Takes no input: everything is copied from the actor's own key.
      The plaintext is returned once in metadata.
      """

      accept []

      change KilnCMS.Accounts.Changes.RotateDraftWriteKey

      # The same mint-time rules as `:create`: the owner is re-checked, so an
      # owner promoted to editor since the original mint cannot rotate.
      validate KilnCMS.Accounts.Validations.DraftWriteKey

      # The owner's row first, refusing an erased account (#2514). The foreign
      # key alone would wait for an erasure of a rejected registration and then
      # mint a key for the tombstone.
      change KilnCMS.Accounts.Changes.LockAccount

      change {AshAuthentication.Strategy.ApiKey.GenerateApiKey,
              prefix: @prefix, hash: :api_key_hash}

      # Audit log (#2241), in the transaction. The name and scope only, never the
      # key or its hash.
      change {KilnCMS.Security.Changes.Record,
              type: :api_key_created,
              target: fn record, _changeset -> {"api_key", record.id} end,
              metadata: fn record, _changeset ->
                %{"name" => record.name, "scope" => record.access}
              end}
    end

    read :live_in_lineage do
      description "The unrevoked keys of a rotation lineage (reuse detection)."
      argument :lineage_id, :uuid, allow_nil?: false
      filter expr(lineage_id == ^arg(:lineage_id) and is_nil(revoked_at))
    end

    update :retire_rotated do
      description """
      Revoke a key inside its own `:rotate` transaction. `:revoke` minus the
      socket eviction, which `:rotate` does itself after its commit: a nested
      action's after-commit hook would fire while the rotation is still open.
      Called only by `Changes.RotateDraftWriteKey`; admin-only like `:revoke`.
      """

      accept []
      require_atomic? false
      change set_attribute(:revoked_at, &DateTime.utc_now/0)

      # Audit log (#2241), in the transaction; a repeat revoke of a key already
      # revoked records nothing.
      change {KilnCMS.Security.Changes.Record,
              type: :api_key_revoked,
              when: fn _record, changeset -> is_nil(changeset.data.revoked_at) end,
              target: fn record, _changeset -> {"api_key", record.id} end,
              metadata: fn record, _changeset -> %{"name" => record.name} end}
    end

    update :revoke do
      description "Revoke a key immediately (idempotent). Sets `revoked_at`."
      accept []
      require_atomic? false
      change set_attribute(:revoked_at, &DateTime.utc_now/0)

      # A key is the *entire* credential of `KilnCMSWeb.BridgeSocket`, which
      # authorizes once at connect and then streams drafts. Revoking a leaked
      # key did not stop the leak until the tab closed (#675). Keyed on the
      # owning user, so this also drops their other sockets — a reconnect
      # re-authorizes, so the cost is a reconnect and the alternative is a live
      # socket holding a revoked credential.
      #
      # After commit: a revoke inside `:rotate` runs in that action's open
      # transaction, and an evicted socket that reconnected before the COMMIT
      # would re-authorize against the still-unrevoked row.
      change {KilnCMS.Accounts.Changes.EvictSessions,
              reason: :api_key_revoked, user_id: :user_id, after_commit?: true}

      # Audit log (#2241), in the transaction; a repeat revoke of a key already
      # revoked records nothing.
      change {KilnCMS.Security.Changes.Record,
              type: :api_key_revoked,
              when: fn _record, changeset -> is_nil(changeset.data.revoked_at) end,
              target: fn record, _changeset -> {"api_key", record.id} end,
              metadata: fn record, _changeset -> %{"name" => record.name} end}
    end
  end

  policies do
    # The API-key sign-in flow looks up the key through the user's
    # `valid_api_keys` relationship as a trusted auth interaction.
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    # Self-rotation: the actor authenticated with a `:draft_write` key that is
    # still valid and still inside its admin-set rotation window. Nothing else
    # may run it, admins included — an admin mints instead. What the new key
    # carries is copied from the actor's own key by the action's change, so the
    # check need not (and cannot be tricked into) judging any input.
    policy action(:rotate) do
      authorize_if KilnCMS.Accounts.Checks.RotatableDraftWriteKey
    end

    # Minting, listing and revoking keys is an operator task — admins only.
    # Listed by action rather than `always()` so `:rotate` is judged by its own
    # policy alone; a create action added later matches no policy and is refused.
    #
    # One exception: accepting a site invitation over an unconfirmed account
    # (#2453) lists that account's keys and revokes them, as the invitations
    # system actor (`Changes.ForgetPriorCredentials`), so a key minted for
    # whoever registered the address first stops working when the invitee
    # takes it over.
    policy action_type([:read, :update, :destroy]) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin

      authorize_if {KilnCMS.Checks.SystemActor,
                    subsystem: :invitations, action: [:for_user, :revoke]}
    end

    policy action(:create) do
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
    end
  end

  attributes do
    uuid_primary_key :id

    # Human-facing label so an admin can tell keys apart in the UI.
    attribute :name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.line()]

    # SHA-256 of the plaintext key. Never returned by reads.
    attribute :api_key_hash, :binary do
      allow_nil? false
      sensitive? true
    end

    # What the key may do as its owning user. `:read` keys are delivery-only;
    # `:read_write` keys may also author content (the content policy reads this
    # off `actor.__metadata__.api_key` — see Checks.ApiKeyWithoutWriteAccess).
    # Set at mint and immutable after (no update action accepts it): upgrading
    # a credential's power in place is a footgun, so mint a new key instead.
    attribute :access, :atom do
      allow_nil? false
      public? true
      default :read
      constraints one_of: [:read, :read_write, :draft_write]
    end

    # Keys are always expiring — no immortal credentials.
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true

    # Non-nil once revoked; excluded from `valid` and from auth lookups.
    attribute :revoked_at, :utc_datetime_usec, public?: true

    # `:draft_write` only: the last moment this key, or any key rotated from
    # it, may self-rotate (and the latest any successor may expire). nil = not
    # rotatable. Set at mint, copied unchanged on rotation, never updated.
    attribute :rotatable_until, :utc_datetime_usec, public?: true

    # The id shared by every key in a rotation lineage: the original mint's id.
    # nil on a key that has never been rotated from (its lineage is its own id).
    attribute :lineage_id, :uuid, public?: true

    create_timestamp :created_at
  end

  relationships do
    belongs_to :user, KilnCMS.Accounts.User do
      allow_nil? false
    end

    # The key this one was rotated from (nil for an admin mint).
    belongs_to :rotated_from, __MODULE__ do
      public? true
      attribute_writable? false
    end

    # The key this one was rotated into, if it was.
    has_one :rotated_to, __MODULE__ do
      public? true
      destination_attribute :rotated_from_id
    end
  end

  calculations do
    calculate :valid, :boolean, expr(is_nil(revoked_at) and expires_at > now())
  end

  identities do
    identity :unique_api_key_hash, [:api_key_hash]
  end
end
