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
      `:delivery` pipeline and nowhere else, so the snippet is never emitted
      *into* a console page. That is enforced structurally rather than by
      review, which is why it is a pipeline and not a template condition.
    * **Every change is versioned and attributed** (`paper_trail`), so "when did
      this site start loading that script, and who added it" is answerable.

  ### What "delivery only" does NOT buy — read this before granting the role

  **The console shares an origin with the site.** `https://acme.example/editor`
  and `https://acme.example/` are the same origin, so script running on the
  public site is same-origin with the console and does not need to render inside
  it to reach it. A snippet can `fetch("/editor/…", credentials: "same-origin")`
  in the browser of anyone who loads a public page while signed in — and
  `connect_src` is a field on this very row, so the exfiltration channel is
  configured alongside the payload.

  The victim who matters is a **platform admin**, for whom
  `Scoping.effective_tier/2` returns `:admin` on every org. So granting one
  site's admin code injection grants them script execution on the origin your
  console lives on, against anyone with more privilege who visits that site.

  This is inherent to same-origin code injection — Ghost's has the same
  property — and the honest mitigations are deployment-level, not policy-level:

    * serve the console from a host no tenant controls, and keep tenant sites on
      their own hosts; or
    * treat "org admin" on a shared-origin deployment as equivalent to trusting
      that person with the console, and staff it accordingly.

  Do not read the `:delivery` pipeline as a substitute for either. It keeps the
  markup out of console *pages*; it cannot make a same-origin script harmless.

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
  # The shared one-row-per-org shape comes from `KilnCMS.CMS.OrgSettings`
  # (#1080). Public reads, like `SiteBranding` — the snippet is served to
  # anonymous visitors, so its contents are not a secret; tenant-scoped, so it
  # is only ever the requesting site's own row. Writing arbitrary script into a
  # site's pages is an org-admin act, resolved against the REQUEST's org
  # (`Scoping.effective_tier/2` already returns `:admin` for a platform admin
  # on every org, so no bypass clause is needed). `script_hashes` is derived by
  # `Changes.HashInlineScripts`, so it is upsertable without being accepted.
  use KilnCMS.CMS.OrgSettings,
    table: "site_code_injection",
    accept: [:head_html, :footer_html, :script_src, :connect_src, :img_src, :enabled],
    upsert_fields: [
      :head_html,
      :footer_html,
      :script_src,
      :connect_src,
      :img_src,
      :enabled,
      :script_hashes
    ],
    read: :public,
    extensions: [AshPaperTrail.Resource]

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
    # No FK from version -> source. With one, the row becomes UNDELETABLE the
    # moment it has any history — and paper_trail writes history on every save,
    # so "Remove" would raise on every row that has ever been saved. Keeping the
    # audit rows after a delete is also the behaviour you want here: "this site
    # used to run that script and then stopped" is exactly the question. Same
    # choice, for the same reason, as `KilnCMS.CMS.Content`.
    reference_source?(false)
  end

  changes do
    change KilnCMS.CMS.Changes.HashInlineScripts, on: [:create, :update]
    change KilnCMS.CMS.Changes.BustCodeInjection, on: [:create, :update, :destroy]
  end

  validations do
    validate KilnCMS.CMS.Validations.CspOrigins
  end

  attributes do
    # Emitted verbatim, at the end of `<head>` and just before `</body>`
    # respectively. Nothing is sanitized — see the moduledoc.
    #
    # Bounded because both ends of this are shared. The resolved struct lives in
    # the SHARED content cache, so an unbounded snippet competes for the same
    # budget as every other org's hot pages; and the hash scan runs on save in
    # the LiveView process. 64 KB is far more than any real analytics tag and
    # small enough that neither is a lever.
    attribute :head_html, :string, public?: true, constraints: [max_length: 65_536]
    attribute :footer_html, :string, public?: true, constraints: [max_length: 65_536]

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
    # Bounded for a different reason than the HTML: these are concatenated into
    # a response HEADER. Most reverse proxies cap response headers at 8-16 KB
    # and answer 502 past it, so without a cap a saved settings value could take
    # a site's public delivery down. 32 origins of 253 bytes (the DNS name
    # limit) stays well inside that even with all three lists full.
    attribute :script_src, {:array, :string},
      default: [],
      public?: true,
      constraints: [max_length: 32, items: [max_length: 253]]

    attribute :connect_src, {:array, :string},
      default: [],
      public?: true,
      constraints: [max_length: 32, items: [max_length: 253]]

    attribute :img_src, {:array, :string},
      default: [],
      public?: true,
      constraints: [max_length: 32, items: [max_length: 253]]

    # Base64 SHA-256 of each inline `<script>` body in the snippet, derived on
    # write by `Changes.HashInlineScripts`. Not writable from input: it is a
    # function of `head_html`/`footer_html`, and accepting it would let a caller
    # authorize a script the snippet does not contain.
    attribute :script_hashes, {:array, :string} do
      default []
      writable? false
      public? true
    end
  end
end
