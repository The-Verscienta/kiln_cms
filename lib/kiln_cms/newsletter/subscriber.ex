defmodule KilnCMS.Newsletter.Subscriber do
  @moduledoc """
  A newsletter subscriber — an external email address that has opted in to
  receive newsletters. Distinct from `KilnCMS.Accounts.User`: a subscriber has
  no login and no password, only an address, an opt-in status, and tokens for
  the public confirm/unsubscribe links.

  Double opt-in: a public `:subscribe` lands on `:pending` and mails a
  confirmation link; clicking it (`:confirm`) flips to `:confirmed`, and only
  confirmed subscribers are mailed. `:unsubscribe` is honoured indefinitely via
  a stored (non-expiring) token so links in old newsletters keep working.

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

      change set_attribute(:status, :pending)
      change set_attribute(:confirm_token, &KilnCMS.Newsletter.Subscriber.generate_token/0)
      change set_attribute(:unsubscribe_token, &KilnCMS.Newsletter.Subscriber.generate_token/0)
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
    read :by_confirm_token do
      get? true
      argument :token, :string, allow_nil?: false
      filter expr(confirm_token == ^arg(:token))
    end

    read :by_unsubscribe_token do
      get? true
      argument :token, :string, allow_nil?: false
      filter expr(unsubscribe_token == ^arg(:token))
    end
  end

  policies do
    # Admin-only management. Public subscribe/confirm/unsubscribe and the send
    # pipeline run as the system (`authorize?: false`) behind token checks.
    policy always() do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    uuid_primary_key :id

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
    attribute :unsubscribed_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
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
