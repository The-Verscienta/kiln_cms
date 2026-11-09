defmodule KilnCMS.CMS.SiteRegistration do
  @moduledoc """
  Whether a self-registration on this site waits for a site admin's approval
  (#2251): `approval_required`, off by default and for a site with no row.

  When it is on, `:register_with_password` on this site's host still creates
  the account, and records a `:pending` `KilnCMS.Accounts.OrgMembership` beside
  it (`KilnCMS.Accounts.Changes.QueueRegistration`). Until an admin approves it
  under `/editor/registrations` the account may sign in but holds nothing on
  any site (`KilnCMS.Accounts.Scoping`). Invitations, a site's own SSO and the
  instance's SSO are not queued. With open registration switched off for the
  deployment (`:registration_enabled`) the setting has nothing to act on.

  The site decides; there is no operator default (ADR 0018 only constrains a
  site against a ceiling, and this has none). `KilnCMS.Accounts.RegistrationPolicy`
  resolves it, failing **closed**: a row that cannot be read refuses the
  registration rather than letting it in unreviewed.

  One row per organization, created lazily, admin-only to read and write — the
  `KilnCMS.CMS.SitePasswordPolicy` shape. The registration reads it as
  `KilnCMS.OrgSettings.system(:registrations)` (`system_actions:` admits `read`
  and nothing else), because a registration has no admin actor to read it as.
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_registration",
    accept: [:approval_required],
    read: :admin,
    admin_columns: [:approval_required, :updated_at],
    system_actions: [read: :registrations]

  attributes do
    attribute :approval_required, :boolean do
      default false
      allow_nil? false
      public? true
    end
  end
end
