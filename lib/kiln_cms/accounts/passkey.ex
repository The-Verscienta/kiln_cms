defmodule KilnCMS.Accounts.Passkey do
  @moduledoc """
  A WebAuthn credential ("passkey") registered to a user account (#331).

  One row per authenticator credential: the base64url credential id (the
  client-side handle), the COSE public key it verified with, and the signature
  counter for clone detection. A user can hold several (laptop, phone, security
  key). The ceremony itself — challenge minting, attestation and assertion
  verification — lives in `KilnCMS.Accounts.WebAuthn`; this resource is the
  storage + self-service management surface (list/rename/remove in
  `/editor/settings`).

  Writes happen only from the ceremony code after cryptographic verification
  (`authorize?: false` system calls); the policies expose reads and destroys to
  the credential's owner (and admins).
  """
  use Ash.Resource,
    otp_app: :kiln_cms,
    domain: KilnCMS.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # The most passkeys one account may hold (#2247). Each one added mails the
  # owner; twenty covers every device a person owns with room to spare.
  @max_per_account 20

  @doc "The most passkeys one account may hold (#2247, `Validations.PasskeyCap`)."
  @spec max_per_account() :: pos_integer()
  def max_per_account, do: @max_per_account

  postgres do
    table "passkeys"
    repo KilnCMS.Repo

    references do
      reference :user, on_delete: :delete
    end

    custom_indexes do
      # The settings page lists by user; sign-in looks up by credential id
      # (served by the unique identity index).
      index [:user_id]
    end
  end

  actions do
    defaults [:read]

    read :for_user do
      description "A user's registered passkeys (backs /editor/settings)."
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    # Demo mode: a visitor can't add or remove the shared account's passkeys
    # (docs/demo-mode.md). Admins pass.
    destroy :destroy do
      primary? true
      # The audit change below reads the destroyed record.
      require_atomic? false
      validate KilnCMS.Accounts.Validations.NotDemoSharedAccount

      # The owner can't remove their last second factor while a site requires
      # one (#2247). A platform admin removing it for them is unaffected.
      validate KilnCMS.Accounts.Validations.KeepsRequiredSecondFactor

      # Audit log (#2241), in the transaction. Whoever removes it is the actor
      # (the owner, or a platform admin); the owner is the target.
      change {KilnCMS.Security.Changes.Record,
              type: :passkey_removed,
              target: fn record, _changeset -> {"user", record.user_id} end,
              metadata: fn record, _changeset -> %{"name" => record.name} end}
    end

    # Accepting a site invitation over an unconfirmed account (#2453): a
    # passkey whoever registered the address first enrolled must not survive
    # the invitee setting the account up. System-only, as
    # `SystemActor.new(:account_takeover)` from `Changes.ForgetPriorCredentials`,
    # inside the accept's transaction. Recorded with no actor (the invitee did
    # not remove it; the system did, because of what the invitee proved).
    destroy :forget_on_takeover do
      description "Remove a passkey when an invitation takes over an unconfirmed account (system-only)."
      require_atomic? false

      change {KilnCMS.Security.Changes.Record,
              type: :passkey_removed,
              target: fn record, _changeset -> {"user", record.user_id} end,
              metadata: fn record, changeset ->
                %{
                  "name" => record.name,
                  "via" => Map.get(changeset.context, :takeover_via, "invitation")
                }
              end}
    end

    # Called by KilnCMS.Accounts.WebAuthn after Wax verified the attestation —
    # never from user input directly. The ceremony passes the enrolling user
    # as the actor, which is all the demo-mode refusal reads.
    create :register do
      accept [:user_id, :name, :credential_id, :public_key, :sign_count]
      validate KilnCMS.Accounts.Validations.NotDemoSharedAccount

      # Past the site's deadline, a password-only session proves the account's
      # email first (#2247, decision 1b). Decided here, not only on the page.
      change KilnCMS.Accounts.Changes.RequireEnrolmentProof

      # Every passkey added mails the owner (below), so the total and the rate
      # are both bounded (#2247): a stolen session must not be able to turn
      # "an email for every factor added" into a flood.
      validate KilnCMS.Accounts.Validations.PasskeyCap
      change KilnCMS.Accounts.Changes.ThrottlePasskeyRegistration

      # The account's row first, and refused when an invitation took the
      # account over after the enrolling request loaded it (#2453): the
      # stranger's session must not land a passkey on the invitee's account.
      change {KilnCMS.Accounts.Changes.GuardAccountTakeover, lock: :share}

      # Audit log (#2241), in the transaction: the credential and its event
      # commit together. The enrolling user is the actor.
      change {KilnCMS.Security.Changes.Record,
              type: :passkey_added,
              target: fn record, _changeset -> {"user", record.user_id} end,
              metadata: fn record, changeset ->
                KilnCMS.Accounts.Changes.RequireEnrolmentProof.metadata(changeset, %{
                  "name" => record.name
                })
              end}

      # Tell the owner (#2247, decision 1a), after the commit.
      change {KilnCMS.Accounts.Changes.NotifyFactorAdded, kind: :passkey}
    end

    # Post-authentication bookkeeping (clone-detection counter + last use).
    update :bump_usage do
      accept [:sign_count]
      change set_attribute(:last_used_at, &DateTime.utc_now/0)
    end
  end

  policies do
    # System-only, and above the admin bypass: a passing bypass skips every
    # policy after it, so below it a platform admin would be admitted. Only the
    # account-takeover system actor may run it; an admin removes a passkey with
    # `:destroy` (#2453).
    policy action(:forget_on_takeover) do
      authorize_if {KilnCMS.Checks.SystemActor,
                    subsystem: :account_takeover, action: :forget_on_takeover}
    end

    bypass KilnCMS.Accounts.Checks.PlatformAdmin do
      authorize_if always()
    end

    # Owners see and manage their own credentials. The invitations system
    # actor lists an unconfirmed account's passkeys to forget them when an
    # invitation takes the account over (#2453).
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
      authorize_if {KilnCMS.Checks.SystemActor, subsystem: :account_takeover, action: :for_user}
    end

    policy action(:destroy) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # `register`/`bump_usage` run `authorize?: false` from the ceremony code.
    policy action([:register, :bump_usage]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    # A user-facing label ("MacBook Touch ID", "YubiKey").
    attribute :name, :string do
      constraints max_length: KilnCMS.Limits.line()
      allow_nil? false
      default "Passkey"
      public? true
    end

    # base64url (unpadded) encoding of the raw credential id — globally unique
    # per WebAuthn spec (enforced by the identity below).
    attribute :credential_id, :string do
      allow_nil? false
      public? false
    end

    # The COSE public key as an Erlang term (`:erlang.term_to_binary/1` of the
    # CBOR-decoded map Wax returns) — opaque storage, decoded only for Wax.
    attribute :public_key, :binary do
      allow_nil? false
      public? false
      sensitive? true
    end

    # WebAuthn signature counter (0 for most synced/platform passkeys).
    attribute :sign_count, :integer do
      allow_nil? false
      default 0
      public? false
    end

    attribute :last_used_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :user, KilnCMS.Accounts.User do
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    # A credential id belongs to exactly one account (WebAuthn requirement).
    identity :unique_credential, [:credential_id]
  end
end
