defmodule KilnCMS.CMS.FormSpamSettings do
  @moduledoc """
  Per-org configuration for the form spam scorer (#477): a disallowed-keyword
  list, checked by `Kiln.Forms.SpamCheck.Checks.DisallowedKeywords`.

  One row per organization — the `KilnCMS.CMS.SiteBranding` shape, not
  `KilnCMS.CMS.SiteCodeInjection`'s: this is admin-only settings, never
  rendered to a visitor, so it carries no `paper_trail` history and no public
  read policy. The row is created lazily by `:save` (upsert on the
  one-per-org identity) — never by a read, so a site with no configured
  keywords costs nothing until an admin actually sets some. Edited on
  `/editor/forms/settings` (`KilnCMSWeb.FormSettingsLive`, #1232).
  """
  # The shared one-row-per-org shape comes from `KilnCMS.CMS.OrgSettings`
  # (#1080). Never delivered — an org's keyword list is not public information
  # the way branding/code-injection are, so unlike those, no public read here.
  use KilnCMS.CMS.OrgSettings,
    table: "form_spam_settings",
    accept: [:keywords],
    read: :admin,
    admin_columns: [:keywords, :updated_at]

  attributes do
    # Case-insensitive substring matches against every free-text field value
    # a submission carries. Bounded the same way `SiteCodeInjection`'s origin
    # lists are: a settings value should never be able to make the scorer's
    # per-submission work unbounded.
    attribute :keywords, {:array, :string},
      default: [],
      public?: true,
      constraints: [max_length: 200, items: [max_length: 100]]
  end
end
