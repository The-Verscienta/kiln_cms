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
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    uuid_primary_key :id

    # Coerced field values, keyed by FormField name.
    attribute :data, :map, allow_nil?: false, default: %{}, public?: true

    # The locale of the page the form was submitted from, when known.
    attribute :locale, :string, public?: true

    timestamps()
  end

  relationships do
    belongs_to :form, KilnCMS.CMS.Form do
      allow_nil? false
      public? true
    end
  end
end
