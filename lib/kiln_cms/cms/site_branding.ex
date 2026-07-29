defmodule KilnCMS.CMS.SiteBranding do
  @moduledoc """
  Per-site white-label branding tokens (#48): site name, logo, favicon, social
  image, brand colour, and the attribution toggle.

  One row **per organization** — the per-org analogue of the instance-wide
  `KilnCMS.Mail.Settings` singleton, but **tenant-scoped**, and that is the
  whole point: `Checks.OrgAdmin` resolves the actor's tier against the request's
  org, which is only correct on a resource with a `multitenancy` block. A
  tenant-less branding resource would resolve every actor against the *default*
  org and let one site's admin rebrand every other site — the hazard documented
  on `KilnCMS.Mail.Settings`.

  Every token is nullable. A `nil` (or blank) column means "not branded at this
  layer" and falls through to `config :kiln_cms, :branding` and then to the
  stock KilnCMS defaults, so clearing a field in the editor restores the
  operator default rather than blanking the header. `KilnCMS.Branding` is the
  resolved read API; nothing outside it should read this resource directly.

  The row is created lazily by the settings form — `:save` upserts on the
  one-per-org identity — and **never** by a read. Creating it on read (the
  `KilnCMS.Mail.ensure_settings!/0` pattern) would turn every anonymous page
  view into an `INSERT`, since branding renders on the public delivery path.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "site_branding"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    default_accept [
      :site_name,
      :logo_url,
      :favicon_url,
      :social_image_url,
      :brand_color,
      :show_attribution
    ]

    # `require_atomic? false` throughout: the cache-bust and colour-normalize
    # changes run in Elixir, not SQL. Branding writes are rare (an admin saving a
    # settings form), so a transaction per write costs nothing here.
    destroy :destroy do
      primary? true
      require_atomic? false
    end

    # The settings form saves the whole token set in one action whether or not a
    # row exists yet — no get-or-create race. `upsert_fields` is explicit so a
    # partial submission can't null out a field it didn't render.
    create :save do
      primary? true
      upsert? true
      upsert_identity :one_per_org

      upsert_fields [
        :site_name,
        :logo_url,
        :favicon_url,
        :social_image_url,
        :brand_color,
        :show_attribution
      ]
    end

    update :update do
      primary? true
      require_atomic? false
    end
  end

  policies do
    # Branding renders on every public page (header logo, title suffix, JSON-LD
    # publisher), so the tokens are public information — same rationale as
    # `KilnCMS.CMS.Redirect`. The read is tenant-scoped, so this exposes only the
    # requesting site's own row.
    policy action_type(:read) do
      authorize_if always()
    end

    # Writes are an org-admin act, resolved against the REQUEST's org. No
    # platform-admin bypass is needed: `Scoping.effective_tier/2`'s first clause
    # already returns `:admin` for a platform admin on every org.
    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  changes do
    change KilnCMS.CMS.Changes.NormalizeBrandColor, on: [:create, :update]
    change KilnCMS.CMS.Changes.BustBranding, on: [:create, :update, :destroy]
  end

  validations do
    validate KilnCMS.CMS.Validations.BrandTokens
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

    attribute :site_name, :string, public?: true

    # A relative path, or an absolute https:// URL on a host the CSP `img-src`
    # permits — see `KilnCMS.CMS.Validations.BrandTokens`.
    attribute :logo_url, :string, public?: true
    attribute :favicon_url, :string, public?: true
    attribute :social_image_url, :string, public?: true

    # Normalized lowercase `#rrggbb`. Every emitted CSS token is re-derived from
    # the parsed channels by `KilnCMS.Branding.Color`, so no user-supplied byte
    # ever reaches the stylesheet.
    attribute :brand_color, :string, public?: true

    # Whether the public footer keeps the "Powered by" attribution. True by
    # default, so an unconfigured site is unchanged.
    attribute :show_attribution, :boolean do
      default true
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
    end
  end

  identities do
    identity :one_per_org, [:org_id]
  end
end
