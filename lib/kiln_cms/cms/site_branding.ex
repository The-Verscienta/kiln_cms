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
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  # Consecutive nightly verify failures before `app_icon_size` is cleared
  # (#1147). Two, not one: a single CDN blip must not yank a working icon.
  @app_icon_failure_threshold 2

  @doc "How many consecutive re-verify failures clear `app_icon_size` (#1147)."
  @spec app_icon_failure_threshold() :: pos_integer()
  def app_icon_failure_threshold, do: @app_icon_failure_threshold

  postgres do
    table "site_branding"
    repo KilnCMS.Repo
  end

  oban do
    use_tenant_from_record? true

    triggers do
      # Daily — branding is a settings field, not content. After the other
      # nightly retention sweeps so this never contends with them.
      trigger :reverify_app_icon do
        action :reverify_app_icon
        read_action :with_app_icon
        worker_read_action :with_app_icon
        queue :default
        scheduler_cron "50 4 * * *"
        list_tenants KilnCMS.Accounts.ListOrgIds
        where expr(not is_nil(app_icon_url) and app_icon_url != "")

        worker_module_name KilnCMS.CMS.SiteBranding.Workers.ReverifyAppIcon
        scheduler_module_name KilnCMS.CMS.SiteBranding.Schedulers.ReverifyAppIcon
      end
    end
  end

  actions do
    defaults [:read]

    default_accept [
      :site_name,
      :logo_url,
      :favicon_url,
      :social_image_url,
      :app_icon_url,
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

      # Not an attribute: the measured edge may only be written together with
      # the URL it measured. See `KilnCMS.CMS.Changes.PairAppIcon`.
      argument :app_icon_size, :integer

      change KilnCMS.CMS.Changes.PairAppIcon

      upsert_fields [
        :site_name,
        :logo_url,
        :favicon_url,
        :social_image_url,
        # Listing both here does NOT pair them — AshPostgres filters
        # `upsert_fields` down to the attributes actually in the changeset, so
        # a write carrying only the URL would leave the old size in place.
        # `Changes.PairAppIcon` is what makes them one decision; these two
        # entries only say the columns are upsertable at all.
        :app_icon_url,
        :app_icon_size,
        :app_icon_verify_failures,
        :brand_color,
        :show_attribution
      ]
    end

    update :update do
      primary? true
      require_atomic? false

      argument :app_icon_size, :integer

      change KilnCMS.CMS.Changes.PairAppIcon
    end

    # Rows with a configured icon URL — feed for the nightly re-verify (#1147).
    read :with_app_icon do
      description "Site branding rows that have an app icon URL to re-check."
      pagination keyset?: true, required?: false
      filter expr(not is_nil(app_icon_url) and app_icon_url != "")
    end

    # Re-fetch `app_icon_url`, refresh or clear `app_icon_size`. Invoked by the
    # AshOban `:reverify_app_icon` trigger — not by the settings form.
    update :reverify_app_icon do
      description "Re-verify the stored app icon URL and refresh its measured size."
      require_atomic? false
      accept []
      change KilnCMS.CMS.Changes.ReverifyAppIcon
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

    # The nightly re-verify reads + updates as a trusted system job (no actor).
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
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

    attribute :site_name, :string, public?: true, constraints: [max_length: KilnCMS.Limits.line()]

    # A relative path, or an absolute https:// URL on a host the CSP `img-src`
    # permits — see `KilnCMS.CMS.Validations.BrandTokens`.
    attribute :logo_url, :string, public?: true, constraints: [max_length: KilnCMS.Limits.url()]

    attribute :favicon_url, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.url()]

    attribute :social_image_url, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.url()]

    # The home-screen icon for the installable editor PWA (#629). Same shape as
    # the fields above — a path or an absolute URL — but with one extra
    # requirement the others do not have: it must be square, because
    # `icons[].sizes` in the web app manifest is a *declaration* Chromium's
    # installability check believes.
    attribute :app_icon_url, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.url()]

    # The measured square edge of `app_icon_url`, in pixels — written by the
    # server from `KilnCMS.Branding.AppIcon.verify/1`, never typed by an
    # operator. `writable? false` is what makes that true rather than merely
    # intended: the only way in is the `:app_icon_size` argument, and
    # `Changes.PairAppIcon` refuses to carry it across a URL change.
    #
    # `nil` is the load-bearing state: it means "we have not seen this image, or
    # it was not usable", and the manifest then serves the stock icon rather
    # than declaring a size it cannot vouch for. A wrong `sizes` does not
    # degrade the install prompt — it removes it, silently.
    attribute :app_icon_size, :integer, public?: true, writable?: false

    # Consecutive failures of the nightly `AppIcon.verify/1` re-check (#1147).
    # Reset to 0 on a successful verify (save or sweep). At
    # `app_icon_failure_threshold/0` the size is cleared; the URL is not.
    attribute :app_icon_verify_failures, :integer do
      allow_nil? false
      default 0
      public? false
      writable? false
    end

    # Normalized lowercase `#rrggbb`. Every emitted CSS token is re-derived from
    # the parsed channels by `KilnCMS.Branding.Color`, so no user-supplied byte
    # ever reaches the stylesheet.
    attribute :brand_color, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.identifier()]

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
