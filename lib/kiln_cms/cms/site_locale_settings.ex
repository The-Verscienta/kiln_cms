defmodule KilnCMS.CMS.SiteLocaleSettings do
  @moduledoc """
  Per-org locale fallback chains: which translation a reader gets when the one
  they asked for has not been published — `fr-CA → fr → en`.

  The per-org layer above `config :kiln_cms, :i18n, fallbacks: …`; see
  `KilnCMS.I18n.Fallback` for how the two resolve and what every delivery
  surface does with the answer.

  One row per organization — the `KilnCMS.CMS.FeedSettings` shape: admin-only,
  no `paper_trail` history, no public read policy (delivery reads it as a
  cached system read), created lazily by `:save` and never by a read.

  ## `nil` is not `%{}`

  `fallbacks: nil` means *"inherit the operator default"*; `%{}` means *"this
  site configured no chains"*, so every locale falls back to the default locale
  only. And inside the map, a locale mapped to `[]` means *"never fall back"*,
  which is different again from a locale that is absent. `/editor/locales`
  writes the whole map on save and drops the row on "reset".
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_locale_settings",
    accept: [:fallbacks],
    read: :admin,
    admin_columns: [:fallbacks, :updated_at]

  # After COMMIT, like every delivery-facing settings bust — see the change.
  changes do
    change KilnCMS.CMS.Changes.BustLocaleSettings, on: [:create, :update, :destroy]
  end

  validations do
    validate KilnCMS.CMS.Validations.LocaleFallbacks
  end

  attributes do
    # `%{"fr-CA" => ["fr", "en"]}` — locale tag to the ordered locales tried
    # after it. Tags rather than ids because a locale is configuration, not a
    # row; `KilnCMS.CMS.Validations.LocaleFallbacks` holds every tag to the set
    # the deployment runs at write time, and the resolver re-checks at read
    # time for a locale an operator removes later.
    attribute :fallbacks, :map do
      allow_nil? true
      public? true
    end
  end
end
