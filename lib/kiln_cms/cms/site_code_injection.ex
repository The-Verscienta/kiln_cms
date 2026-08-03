defmodule KilnCMS.CMS.SiteCodeInjection do
  @moduledoc """
  Per-site custom `<head>` / `<footer>` HTML for the delivery site (#490) — the
  Ghost "code injection" analogue.

  This is where an org puts its own analytics snippet, verification meta tag, or
  chat widget. Kiln ships **no** tracker and this is the reason it does not need
  to: the operator adds Plausible, Matomo or GA themselves, as their decision
  rather than a Kiln feature.

  ## This resource is stored XSS, on purpose

  Everything in `head_html`/`footer_html` is emitted **verbatim** into the
  delivery page. There is no sanitizer, because a sanitizer would defeat the
  feature — the point is to run a `<script>`. So the whole design is about who
  can write it and where it lands:

    * **Org-admin only to write**, resolved against the *request's* org. This
      resource is separate from `KilnCMS.CMS.SiteBranding` for exactly that
      reason: branding is an ordinary settings surface, and widening it to carry
      arbitrary script would hand every future contributor to that form a much
      larger blast radius.
    * **Delivery only to render.** `KilnCMSWeb.Plugs.CodeInjection` runs in the
      `:delivery` pipeline and nowhere else, so nothing reaches the editor
      console. An org admin who can already write here gains nothing by it; an
      admin of *another* org must never be able to script the console session of
      a Kiln operator, and the one-way pipeline is what guarantees that
      structurally rather than by review.
    * **Every change is versioned and attributed** (`paper_trail`), so "when did
      this site start loading that script, and who added it" is answerable.

  ## Reads are public, deliberately

  The snippet renders on anonymous page views, so the row's *contents* are
  public by construction — anyone can read them with `curl`. The read policy
  says so rather than pretending otherwise, matching `SiteBranding`. The read is
  tenant-scoped, so it exposes only the requesting site's own row.

  ## CSP is part of the record, not an afterthought

  Delivery serves `script-src 'self' 'nonce-…'`, under which a pasted vendor
  snippet does nothing at all: an external `<script src>` is blocked by origin
  and an inline one by the missing nonce. Silently breaking every snippet would
  make this a support trap, so the row carries what it needs to be allowed:

    * `script_src` / `connect_src` / `img_src` — validated origin allowlists
      merged into the delivery CSP for this org only.
    * `script_hashes` — the SHA-256 of every inline `<script>` body in the
      snippet, computed at **save time** and emitted as `'sha256-…'` sources.

  Hashes rather than nonces, and that choice is load-bearing. A nonce is
  per-request, so it cannot exist in a statically exported artifact — and static
  export is one of the surfaces this feature has to cover. A hash is a property
  of the snippet, so the same CSP is correct whether the page was rendered live
  or written to disk an hour ago. Editing the snippet re-derives it; nothing can
  drift, because `Changes.HashInlineScripts` recomputes on every write.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "site_code_injection"
    repo KilnCMS.Repo
  end

  # "Who turned on the tracker, and when" is the question this surface will
  # actually be asked, so the answer is recorded rather than reconstructed.
  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    # The generated `.Version` resource inherits this resource's `:attribute`
    # multitenancy, so `org_id` has to be a real column on it rather than buried
    # in the freeform `changes` map — otherwise version creation, which runs in
    # the same transaction as the write, has no tenant to satisfy the inherited
    # config. Same reason as `KilnCMS.CMS.Content`.
    attributes_as_attributes([:org_id])
    ignore_attributes([:inserted_at, :updated_at])
    # "Who turned on the tracker": nilify on account deletion, because the audit
    # row has to outlive the admin who wrote it.
    belongs_to_actor(:user, KilnCMS.Accounts.User, domain: KilnCMS.Accounts, on_delete: :nilify)
    # The generated version resource gets an authorizer but no policies of its
    # own, which Ash reads as "forbid everything". Reading the history is
    # org-admin only even though the source row is publicly readable: what the
    # site serves now is public, who changed it and what it said last week is
    # not.
    mixin({KilnCMS.CMS.SettingsVersionPolicies, :policies, []})
    # The authorizer is NOT inherited from the source resource — the version
    # module is generated separately — so the mixin's `policies` block has
    # nothing to attach to without this.
    version_extensions(authorizers: [Ash.Policy.Authorizer])
  end

  actions do
    defaults [:read]

    default_accept [:head_html, :footer_html, :script_src, :connect_src, :img_src, :enabled]

    create :save do
      primary? true
      upsert? true
      upsert_identity :one_per_org

      upsert_fields [
        :head_html,
        :footer_html,
        :script_src,
        :connect_src,
        :img_src,
        :enabled,
        :script_hashes
      ]
    end

    update :update do
      primary? true
      require_atomic? false
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end
  end

  policies do
    # Public reads, like `SiteBranding` — the snippet is served to anonymous
    # visitors, so its contents are not a secret. Tenant-scoped, so this is only
    # ever the requesting site's own row.
    policy action_type(:read) do
      authorize_if always()
    end

    # Writing arbitrary script into a site's pages is an org-admin act, resolved
    # against the REQUEST's org. `Scoping.effective_tier/2` already returns
    # `:admin` for a platform admin on every org, so no bypass clause is needed.
    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  changes do
    change KilnCMS.CMS.Changes.HashInlineScripts, on: [:create, :update]
    change KilnCMS.CMS.Changes.BustCodeInjection, on: [:create, :update, :destroy]
  end

  validations do
    validate KilnCMS.CMS.Validations.CspOrigins
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # Emitted verbatim, at the end of `<head>` and just before `</body>`
    # respectively. Nothing is sanitized — see the moduledoc.
    attribute :head_html, :string, public?: true
    attribute :footer_html, :string, public?: true

    # A master switch separate from clearing the fields, so an operator
    # debugging a broken third-party script can turn it off and back on without
    # losing the snippet (and without that round trip being invisible in the
    # version trail).
    attribute :enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

    # Origins added to the delivery CSP **for this org only**. Validated by
    # `KilnCMS.CMS.Validations.CspOrigins`: https scheme, host, optional port,
    # optional leading `*.` label — never a bare `*`, never a keyword like
    # `'unsafe-inline'`, which would let a settings form disable the policy it is
    # extending.
    attribute :script_src, {:array, :string}, default: [], public?: true
    attribute :connect_src, {:array, :string}, default: [], public?: true
    attribute :img_src, {:array, :string}, default: [], public?: true

    # Base64 SHA-256 of each inline `<script>` body in the snippet, derived on
    # write by `Changes.HashInlineScripts`. Not writable from input: it is a
    # function of `head_html`/`footer_html`, and accepting it would let a caller
    # authorize a script the snippet does not contain.
    attribute :script_hashes, {:array, :string} do
      default []
      writable? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end

  identities do
    identity :one_per_org, [:org_id]
  end
end
