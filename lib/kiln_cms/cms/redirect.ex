defmodule KilnCMS.CMS.Redirect do
  @moduledoc """
  A 301 redirect from a retired public path to the content record that used to
  live there (the pathauto companion — Drupal's Redirect module twin).

  Rows are written automatically by `Changes.RecordSlugRedirect` when a
  **published** record's slug changes: the old full path (`/blog/old-slug`)
  points at the record itself (`target_type` + `target_id`), not at a frozen
  destination path — delivery resolves the record's *current* URL at request
  time, so multiple renames never produce redirect chains. Upserting on
  `[:path, :locale]` means a path always redirects to whatever record vacated
  it most recently. Rows are internal (no public API); delivery reads and the
  recording change run system-side.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "redirects"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:path, :locale, :target_type, :target_id]

    # Upsert: whoever vacated the path most recently owns the redirect.
    create :create do
      primary? true
      upsert? true
      upsert_identity :unique_path
    end
  end

  policies do
    # Internal bookkeeping: written by the slug-change hook and read by
    # delivery, both system-side (`authorize?: false`). Admins may inspect or
    # prune rows; nobody else touches them.
    policy always() do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336) — same contract as every per-site
    # resource: set from the tenant, never accepted from input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # The retired public path, with the type prefix but no locale prefix
    # (`/blog/old-slug`, `/old-page`).
    attribute :path, :string, allow_nil?: false, public?: true
    attribute :locale, :string, allow_nil?: false, default: "en", public?: true

    # The record that vacated the path: public type name + id, resolved to its
    # current URL at request time.
    attribute :target_type, :string, allow_nil?: false, public?: true
    attribute :target_id, :uuid, allow_nil?: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
    end
  end

  identities do
    identity :unique_path, [:path, :locale]
  end
end
