defmodule KilnCMS.Newsletter.NewsletterSend do
  @moduledoc """
  The **campaign ledger** for newsletters: one row per "send this post to
  segment X" dispatch, updated as delivery progresses so admins can see what
  went out, to how many recipients, and how many succeeded/failed.

  Lifecycle: created `:pending` by `KilnCMS.Newsletter.send_as_newsletter/2`;
  the fan-out worker sets `:sending` (stamping `total_recipients`) and, once
  every per-recipient job is enqueued, `:sent` (i.e. fully dispatched — actual
  delivery outcomes accrue in `sent_count`/`failed_count` as the mail jobs run).
  Written by the send pipeline as the system; admin-only to read.
  """
  use Ash.Resource,
    domain: KilnCMS.Newsletter,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  admin do
    resource_group :system
    table_columns [:subject, :content_type, :status, :sent_count, :failed_count, :inserted_at]
  end

  postgres do
    table "newsletter_sends"
    repo KilnCMS.Repo

    references do
      # Keep the campaign row if its segment is later deleted.
      reference :segment, on_delete: :nilify
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:content_type, :content_id, :subject, :segment_id, :sent_by_id]
    end

    # Fan-out started: record how many recipients resolved.
    update :mark_sending do
      accept [:total_recipients]
      change set_attribute(:status, :sending)
    end

    # Every per-recipient job has been enqueued.
    update :mark_sent do
      accept []
      change set_attribute(:status, :sent)
      change set_attribute(:sent_at, &DateTime.utc_now/0)
    end

    update :mark_failed do
      accept []
      change set_attribute(:status, :failed)
    end

    # Per-recipient delivery outcomes. Atomic so concurrent mail workers can't
    # lose increments to a read-modify-write race.
    update :record_sent do
      change atomic_update(:sent_count, expr(sent_count + 1))
    end

    update :record_failed do
      change atomic_update(:failed_count, expr(failed_count + 1))
    end

    read :recent do
      prepare build(sort: [inserted_at: :desc], limit: 25)
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  # Multi-tenancy (epic #336): a campaign belongs to the site whose content it
  # sends. `global?: true` keeps the tenant optional; `create_send` carries the
  # document's org, and the send/mail workers scope their reads to `send.org_id`
  # (retiring the default-org fallback the rollout left in `KilnCMS.Newsletter`).
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant (the document's
    # org) on create, else the default org.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # The published document this campaign rendered (`"post"` / `"page"` /
    # `"entry"`) + its id. A soft polymorphic reference (matching how the firing
    # engine keys artifacts), not an FK.
    attribute :content_type, :string, allow_nil?: false, public?: true
    attribute :content_id, :uuid, allow_nil?: false, public?: true

    attribute :subject, :string, allow_nil?: false, public?: true

    attribute :status, :atom do
      constraints one_of: [:pending, :sending, :sent, :failed]
      default :pending
      allow_nil? false
      public? true
    end

    attribute :total_recipients, :integer, allow_nil?: false, default: 0, public?: true
    attribute :sent_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :failed_count, :integer, allow_nil?: false, default: 0, public?: true

    # The admin who triggered the send (plain reference, no FK across domains).
    attribute :sent_by_id, :uuid, public?: true

    attribute :sent_at, :utc_datetime_usec, public?: true

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

    belongs_to :segment, KilnCMS.Newsletter.Segment do
      public? true
    end
  end
end
