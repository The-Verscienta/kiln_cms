defmodule KilnCMS.CMS.FormSubmission do
  @moduledoc """
  One accepted submission of an admin-defined `Form`: the coerced `data` map
  (only defined field keys, JSON-native values) plus when it arrived.
  Privacy-first like the rest of the analytics surface: **no IP, no user
  agent** — rate limiting uses the IP transiently and discards it.

  Written exclusively by `KilnCMS.Forms.submit/3` (validation, honeypot, and
  rate limiting happen there); admin-only to read, delete, or export.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  admin do
    resource_group :content
    table_columns [:form_id, :inserted_at]
  end

  postgres do
    table "form_submissions"
    repo KilnCMS.Repo

    references do
      reference :form, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:form_id, :data, :locale]
    end

    # Recent submissions of one form, newest first (admin viewer).
    read :recent_for_form do
      argument :form_id, :uuid, allow_nil?: false
      filter expr(form_id == ^arg(:form_id))
      prepare build(sort: [inserted_at: :desc], limit: 100)
    end
  end

  policies do
    # Submission contents are visitor-provided data — admin eyes only. The
    # accept pipeline writes with authorize?: false after validating.
    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  # Multi-tenancy (epic #336): a submission belongs to the same site as its form.
  # `global?: true` keeps the tenant optional; the delivery-path create
  # (`KilnCMS.Forms.record`, `authorize?: false`) MUST carry the form's tenant so
  # the submission lands in the right site (see `KilnCMS.Forms`).
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant (the form's org) on
    # the delivery-path create, else the default org.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # Coerced field values, keyed by FormField name.
    attribute :data, :map, allow_nil?: false, default: %{}, public?: true

    # The locale of the page the form was submitted from, when known.
    attribute :locale, :string, public?: true

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

    belongs_to :form, KilnCMS.CMS.Form do
      allow_nil? false
      public? true
    end
  end
end
