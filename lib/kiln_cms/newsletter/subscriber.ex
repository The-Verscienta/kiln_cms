defmodule KilnCMS.Newsletter.Subscriber do
  @moduledoc """
  A newsletter subscriber — an external email address that has opted in to
  receive newsletters. Distinct from `KilnCMS.Accounts.User`: a subscriber has
  no login and no password, only an address, an opt-in status, and tokens for
  the public confirm/unsubscribe links.

  Double opt-in: a public `:subscribe` lands on `:pending` and mails a
  confirmation link (`KilnCMS.Newsletter.Changes.SendConfirmationEmail`);
  clicking it (`:confirm`) flips to `:confirmed`, and only confirmed subscribers
  are mailed. `:unsubscribe` is honoured indefinitely via a stored
  (non-expiring) token so links in old newsletters keep working.

  Admin-managed; the public subscribe/confirm/unsubscribe flows run
  `authorize?: false` behind token verification (mirroring
  `KilnCMS.Mail.SuppressedRecipient`).
  """
  use Ash.Resource,
    domain: KilnCMS.Newsletter,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  admin do
    resource_group :system
    table_columns [:email, :name, :status, :confirmed_at, :inserted_at]
  end

  postgres do
    table "newsletter_subscribers"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]

    # Public opt-in. Upserts on email so a repeat sign-up refreshes the name
    # without resetting an existing subscriber's status or tokens (upsert_fields
    # is name-only) — a confirmed subscriber re-submitting the form stays
    # confirmed, and an unsubscribed one is not silently re-subscribed.
    create :subscribe do
      accept [:email, :name]
      upsert? true
      upsert_identity :unique_email
      upsert_fields [:name]

      validate KilnCMS.Newsletter.Validations.EmailAddress

      change set_attribute(:status, :pending)
      change set_attribute(:confirm_token, &KilnCMS.Newsletter.Subscriber.generate_token/0)
      change set_attribute(:unsubscribe_token, &KilnCMS.Newsletter.Subscriber.generate_token/0)

      # The half of double opt-in that was missing until #586: mail the link.
      # Only a `:pending` result is mailed, so the upsert above stays
      # non-resurrecting — see the change's moduledoc.
      change KilnCMS.Newsletter.Changes.SendConfirmationEmail
    end

    # Link a paying member to their subscriber row (#337 Phase 2).
    #
    # `upsert_fields [:user_id]` applies the SAME non-resurrection rule as
    # `:subscribe` above: an existing row's `status` is never touched, so an
    # UNSUBSCRIBED person who buys a membership gets linked but stays
    # unsubscribed. That is the "opt out of email without cancelling your paid
    # subscription" requirement, enforced by the action rather than by callers
    # remembering.
    #
    # A brand-new row lands `:pending`, not `:confirmed`: paying for access is not
    # consent to marketing email, and this subscriber model is double opt-in
    # throughout. Change the `set_attribute(:status, …)` below to `:confirmed` if
    # your jurisdiction and policy treat purchase as the consent event.
    create :link_member do
      accept [:email, :name]
      upsert? true
      upsert_identity :unique_email
      upsert_fields [:user_id]

      argument :user_id, :uuid, allow_nil?: false

      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:status, :pending)
      change set_attribute(:confirm_token, &KilnCMS.Newsletter.Subscriber.generate_token/0)
      change set_attribute(:unsubscribe_token, &KilnCMS.Newsletter.Subscriber.generate_token/0)
    end

    # Self-service opt-in from `/account`. Consent given while signed in to a
    # verified account is the double-opt-in equivalent — the link-click exists to
    # prove the address belongs to the person, which the session already does.
    update :resubscribe do
      accept []
      change set_attribute(:status, :confirmed)
      change set_attribute(:confirmed_at, &DateTime.utc_now/0)
      change set_attribute(:unsubscribed_at, nil)
    end

    # Every subscriber row linked to one account, across organizations — the
    # member's own newsletter state on each site they belong to.
    read :for_user do
      multitenancy :bypass
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    # Double opt-in: the subscriber clicked the confirmation link.
    update :confirm do
      accept []
      change set_attribute(:status, :confirmed)
      change set_attribute(:confirmed_at, &DateTime.utc_now/0)
    end

    # Honoured indefinitely (stored token, no expiry). Consent, not deliverability
    # — deliberately distinct from bounce-suppression (`SuppressedRecipient`).
    update :unsubscribe do
      accept []
      change set_attribute(:status, :unsubscribed)
      change set_attribute(:unsubscribed_at, &DateTime.utc_now/0)
    end

    # Confirmed subscribers, optionally scoped to one segment. The single source
    # of truth for "who gets this newsletter" — used by the send fan-out.
    read :confirmed do
      argument :segment_id, :uuid, allow_nil?: true

      filter expr(
               status == :confirmed and
                 (is_nil(^arg(:segment_id)) or exists(segments, id == ^arg(:segment_id)))
             )
    end

    # Public token lookups (confirm/unsubscribe links). Non-identity fields, so
    # they're explicit filtered reads rather than `get_by`.
    #
    # DELIBERATE GLOBAL READS (#419): the org is unknown until the row is
    # found — the token itself is the secret, and the caller re-scopes the
    # follow-up write with the found row's `org_id`. `multitenancy :bypass` is
    # the sanctioned per-action exception under the strict `global?: false`
    # resource default.
    read :by_confirm_token do
      get? true
      multitenancy :bypass
      argument :token, :string, allow_nil?: false
      filter expr(confirm_token == ^arg(:token))
    end

    read :by_unsubscribe_token do
      get? true
      multitenancy :bypass
      argument :token, :string, allow_nil?: false
      filter expr(unsubscribe_token == ^arg(:token))
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # Linking a member is driven by billing, never by a human (#337 Phase 2) —
    # it is the one write that may set `user_id`.
    policy action(:link_member) do
      forbid_if always()
    end

    # A signed-in member manages their OWN newsletter consent from `/account`.
    # Scoped to their linked row, so this grants nothing over anyone else's.
    #
    # A BYPASS, not a `policy` (#586). Ash AND-combines every applicable policy,
    # so as a plain policy this was silently narrowed to nothing by the blanket
    # admin policy below — a member is not an admin, so `:resubscribe` came back
    # Forbidden and `:for_user` filtered to `[]`. That is the same trap the note
    # on the write policies warns about, one level up: repeating the admin grant
    # here doesn't help, because the *self* grant is the one being ANDed away.
    # A passing bypass short-circuits the rest; a failing one falls through, so
    # an admin still reaches these actions via the blanket policy.
    #
    # `not is_nil(user_id)` is load-bearing: without it an actor-less caller
    # templates `^actor(:id)` to nil and the check reduces to `user_id == nil`,
    # which would match every unlinked subscriber row on the site.
    bypass action([:resubscribe, :unsubscribe, :for_user]) do
      authorize_if expr(not is_nil(user_id) and user_id == ^actor(:id))
    end

    # Admin-only management. Public subscribe/confirm/unsubscribe and the send
    # pipeline run as the system (`authorize?: false`) behind token checks.
    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  # Multi-tenancy (epic #336, strict since #419): a subscriber belongs to one
  # site, so the same email can subscribe to two sites independently. Every
  # action requires a tenant except the two token lookups above
  # (`multitenancy :bypass` — the token is the secret), whose follow-up
  # updates use the found row's own org.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant on subscribe, else
    # the default org; never accepted from input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :name, :string, public?: true

    attribute :status, :atom do
      constraints one_of: [:pending, :confirmed, :unsubscribed]
      default :pending
      allow_nil? false
      public? true
    end

    # Opaque random tokens for the public confirm/unsubscribe links. Not
    # accepted from input (set only by `:subscribe`); sensitive so they stay out
    # of inspect/logs.
    attribute :confirm_token, :string, sensitive?: true
    attribute :unsubscribe_token, :string, sensitive?: true

    attribute :confirmed_at, :utc_datetime_usec, public?: true

    # The account this subscriber belongs to, when it is a member (#337 Phase 2).
    # A real FK rather than matching on email: a person can change their address,
    # and email-matching would silently orphan the link when they do.
    attribute :user_id, :uuid do
      writable? false
      public? false
    end

    attribute :unsubscribed_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    # The owning organization — the tenant axis is the `org_id` attribute above.
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

    many_to_many :segments, KilnCMS.Newsletter.Segment do
      through KilnCMS.Newsletter.SegmentMembership
      source_attribute_on_join_resource :subscriber_id
      destination_attribute_on_join_resource :segment_id
      public? true
    end
  end

  identities do
    identity :unique_email, [:email]
  end

  @doc false
  def generate_token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
