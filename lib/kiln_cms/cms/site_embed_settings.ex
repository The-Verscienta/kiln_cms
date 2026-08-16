defmodule KilnCMS.CMS.SiteEmbedSettings do
  @moduledoc """
  Per-org default for who may frame a form's embed page (#1131).

  Follow-up to #648, which put the `frame-ancestors` allowlist on the
  **form**: correct for "this one partner needs this one form," but an org
  with a dozen forms sets the same allowlist a dozen times, and every form
  that has never been opened — every existing one, and every new one — is
  still governed by the deployment-wide `EMBED_ORIGINS` until somebody does.
  On a multi-org deployment that variable is necessarily the union of every
  org's embedders, which is #562's overlay-and-harvest attack one tenant
  boundary over.

  This resource is the middle rung `KilnCMS.Forms.EmbedPolicy` resolves:

      form.embed_origins  ->  SiteEmbedSettings.embed_origins  ->  EMBED_ORIGINS

  `KilnCMS.CMS.Form`'s own three states apply here unchanged, and for the
  same reason — `nil` (no row, or a row with `embed_origins: nil`) means
  "this org has not set a default, fall through to the deployment"; `[]`
  means "same-origin only for every form in this org that hasn't set its
  own," a deliberate close distinct from absence; a non-empty list is this
  org's allowlist. `KilnCMS.Forms.EmbedPolicy.effective/1` is where those
  states get read and folded into a form's effective policy — nothing else
  should read this resource directly, the same "own_origins/1 is the only
  reader of the shape" discipline `KilnCMSWeb.Embed` documents for the form
  half of the ladder.

  Admin-only, like `KilnCMS.CMS.FormSpamSettings` (never delivered to a
  visitor, no `paper_trail`). Edited on `/editor/forms/settings`
  (`KilnCMSWeb.FormSettingsLive`, #1232) — it shipped managed only through
  the generic Ash Admin resource UI, which is compiled out in production, so
  an org admin had no way to reach it there. One row per org, created lazily
  by `:save` so a site that never sets a default costs nothing.
  """
  # The shared one-row-per-org shape comes from `KilnCMS.CMS.OrgSettings`
  # (#1080). Never delivered — this is the operator-facing half of a framing
  # policy, not content; no public read, unlike SiteBranding/SiteCodeInjection.
  use KilnCMS.CMS.OrgSettings,
    table: "site_embed_settings",
    accept: [:embed_origins],
    read: :admin,
    admin_columns: [:embed_origins, :updated_at]

  validations do
    # Same predicate `Form.embed_origins` uses — this list is concatenated
    # into the same header, so it is the same hazard: keyword sources and
    # header-injection characters, checked here rather than trusting every
    # form's own validation to catch a value that never passed through it.
    validate {KilnCMS.CMS.Validations.CspOrigins, fields: [:embed_origins]}

    # After the shape check, and only under `EMBED_ORIGINS_LOCKED` (#1133): a
    # list that reaches outside the operator's ceiling is refused, naming the
    # offending entries and never the ceiling. See `KilnCMS.Forms.EmbedCeiling`.
    validate {KilnCMS.CMS.Validations.EmbedCeiling, field: :embed_origins}
  end

  attributes do
    # Same three states, same bound, as `Form.embed_origins` — see that
    # attribute's doc for why `nil` and `[]` must stay distinct, and why 16
    # entries at the DNS name limit.
    attribute :embed_origins, {:array, :string},
      public?: true,
      constraints: [max_length: 16, items: [max_length: 253]]
  end
end
