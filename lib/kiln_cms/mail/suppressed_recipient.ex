defmodule KilnCMS.Mail.SuppressedRecipient do
  @moduledoc """
  An email address that hard-bounced (a permanent 5xx reject) and should not
  be mailed again until an admin clears it.

  Written by the delivery pipeline on a permanent failure
  (`KilnCMS.Mail.deliver_for_worker/2`) and consulted by
  `KilnCMS.Mail.enqueue!/1`, which drops suppressed recipients before queuing
  — so a dead address isn't re-attempted on every future send, which wastes
  retries and signals spamminess to receivers. Admin-managed (viewable and
  removable from `/editor/mail`).

  The address is a `ci_string`, so suppression and lookup are
  case-insensitive.
  """
  use Ash.Resource,
    domain: KilnCMS.Mail,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "suppressed_recipients"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]

    # Upsert: a repeat bounce for an already-suppressed address just refreshes
    # the reason and timestamp rather than erroring on the unique identity.
    create :suppress do
      accept [:email, :reason]
      upsert? true
      upsert_identity :unique_email
      upsert_fields [:reason, :last_failure_at]
      change set_attribute(:last_failure_at, &DateTime.utc_now/0)
    end
  end

  policies do
    # Admin-only management. The delivery pipeline writes and reads suppressions
    # as the system (`authorize?: false`) — like the webhook delivery worker.
    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string, allow_nil?: false, public?: true

    # The redacted SMTP reason for the bounce (never contains the address).
    attribute :reason, :string, public?: true

    attribute :last_failure_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  identities do
    identity :unique_email, [:email]
  end
end
