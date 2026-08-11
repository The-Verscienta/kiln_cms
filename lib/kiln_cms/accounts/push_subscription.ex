defmodule KilnCMS.Accounts.PushSubscription do
  @moduledoc """
  A Web Push subscription registered by a reviewer's browser (#628).

  One row per browser per account: the push service's `endpoint` URL and the
  two keys it hands out — `p256dh` (the browser's ECDH public key) and `auth`
  (a 16-byte secret). `KilnCMS.Push.Encryption` needs both to encrypt a payload
  the push service itself cannot read.

  Modelled on `KilnCMS.Accounts.Passkey`: a per-user credential the owner
  manages from `/editor/settings`, written only by the flow that created it and
  readable only by its owner (and admins).

  ## The endpoint is the identity, and it is a bearer capability

  A push endpoint URL is unguessable and anyone holding it can ask the push
  service to wake that browser — VAPID stops *unsigned* senders, not someone
  who has the URL. So the column is `sensitive?` (kept out of logged
  changesets and error output) and `public? false`, and no read action returns
  it to a client: the settings page lists subscriptions by `label` and
  `inserted_at`, never by endpoint.

  Unique on `endpoint` alone rather than `[user_id, endpoint]`: a push service
  mints one endpoint per browser instance, and if the same browser is later
  used to sign in as somebody else, the *second* subscription is the true owner
  — the first account's notifications must stop going to a device that now
  belongs to another session. The upsert moves the row rather than adding one.

  ## Why `org_id` is here but does not scope the policy

  Rows carry the org the subscription was created under so an operator can see
  where a device came from, and so a future per-site notification setting has
  something to filter on. Authorization stays keyed on `user_id`: a user's own
  devices are theirs across every site they belong to, and scoping the read by
  tenant would hide a reviewer's own subscription from them on a second site
  while still pushing to it.
  """
  use Ash.Resource,
    otp_app: :kiln_cms,
    domain: KilnCMS.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "push_subscriptions"
    repo KilnCMS.Repo

    references do
      reference :user, on_delete: :delete
    end

    custom_indexes do
      # The settings page and the sender both list by user.
      index [:user_id]
    end
  end

  actions do
    defaults [:read, :destroy]

    read :for_user do
      description "A user's registered devices (backs /editor/settings)."
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :for_users do
      description "Every subscription belonging to any of `user_ids` — the sender's read."
      argument :user_ids, {:array, :uuid}, allow_nil?: false
      filter expr(user_id in ^arg(:user_ids))
    end

    # A browser re-subscribing produces the same endpoint, so this is an upsert
    # rather than a create: a reviewer toggling the setting off and on, or a
    # service worker refreshing its subscription, must not accumulate rows that
    # all resolve to one device and send it three copies of every notification.
    create :subscribe do
      accept [:user_id, :org_id, :endpoint, :p256dh, :auth, :label]
      upsert? true
      upsert_identity :unique_endpoint
      upsert_fields [:user_id, :org_id, :p256dh, :auth, :label]

      # `allow_nil? false` does not reject `""`, and the browser hands back an
      # empty string whenever `getKey/1` returned null. Without these the row
      # stores, the UI says notifications are on, and the first delivery fails
      # the encryption's own length check and prunes the row — so the reviewer
      # is told it worked and never hears anything again.
      validate string_length(:endpoint, min: 1)
      validate string_length(:p256dh, min: 1)
      validate string_length(:auth, min: 1)

      # The push service URL we will POST to. `SafeFetch` refuses a private
      # address at dial time; this refuses a shape that was never a push
      # endpoint, so a bad row is rejected where somebody can see it rather
      # than once per notification in a worker log.
      validate match(:endpoint, ~r{\Ahttps://})
    end

    # Delivery bookkeeping, and the only update this resource has. A general
    # `:update` would let anything rewrite an endpoint or a key, which is the
    # one write that must only ever come from a browser's own subscribe call.
    update :touch_delivered do
      accept []
      change set_attribute(:last_delivered_at, &DateTime.utc_now/0)
    end
  end

  policies do
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type(:destroy) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # System calls, all three: `subscribe` writes the endpoint keys after the
    # LiveView has established the actor, `for_users` is the sender's read, and
    # `touch_delivered` is the worker's bookkeeping.
    policy action([:subscribe, :for_users, :touch_delivered]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    # The push service URL to POST to. Unguessable and sufficient on its own to
    # wake the device — see the moduledoc.
    attribute :endpoint, :string do
      allow_nil? false
      public? false
      sensitive? true
      constraints max_length: 2048
    end

    # The browser's ECDH public key, base64url. Decoded by `KilnCMS.Push`.
    attribute :p256dh, :string do
      allow_nil? false
      public? false
      constraints max_length: 255
    end

    # The 16-byte auth secret, base64url.
    attribute :auth, :string do
      allow_nil? false
      public? false
      sensitive? true
      constraints max_length: 64
    end

    # What the settings page shows instead of the endpoint. The browser cannot
    # tell us the device name, so this is a coarse user-agent family the client
    # derives — enough to recognize "the phone" from "the laptop".
    # 60 rather than `Limits.line()`: this is a device name in a list, not
    # prose, and the writer truncates to the same number — one limit, in one
    # place, so the constraint can actually fire.
    attribute :label, :string do
      allow_nil? false
      default "Browser"
      public? true
      constraints max_length: 60
    end

    # Set when a push service last accepted a message. Nil means "registered but
    # never used", which is how a subscription that was never deliverable looks.
    attribute :last_delivered_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :user, KilnCMS.Accounts.User do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :org, KilnCMS.Accounts.Organization do
      allow_nil? true
      attribute_writable? true
      source_attribute :org_id
    end
  end

  identities do
    identity :unique_endpoint, [:endpoint]
  end
end
