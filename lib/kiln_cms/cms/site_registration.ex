defmodule KilnCMS.CMS.SiteRegistration do
  @moduledoc """
  Whether a self-registration on this site waits for a site admin's approval
  (#2251): `approval_required`, off by default and for a site with no row.

  When it is on, `:register_with_password` on this site's host still creates
  the account, and records a `:pending` `KilnCMS.Accounts.OrgMembership` beside
  it (`KilnCMS.Accounts.Changes.QueueRegistration`). Until an admin approves it
  under `/editor/registrations` the account may sign in but holds nothing on
  any site (`KilnCMS.Accounts.Scoping`). Invitations and the instance's SSO are
  not queued. With open registration switched off for the deployment
  (`:registration_enabled`) the setting has nothing to act on.

  `approval_for_site_sso` does the same for a **new** account this site's own
  single sign-on provisions (`KilnCMS.Accounts.SiteSso.Admission`): the
  account is created and its membership here is `:pending`, not `:viewer`.
  It is independent of `approval_required`: a site may let its own provider's
  people straight in while holding password sign-ups, or the other way round.
  An account that already exists is admitted as it always was.

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
    accept: [:approval_required, :approval_for_site_sso],
    read: :admin,
    admin_columns: [:approval_required, :approval_for_site_sso, :updated_at],
    system_actions: [read: :registrations]

  attributes do
    attribute :approval_required, :boolean do
      default false
      allow_nil? false
      public? true
    end

    # A new account this site's own single sign-on provisions waits too
    # (#2514). Off by default and independent of `approval_required`.
    attribute :approval_for_site_sso, :boolean do
      default false
      allow_nil? false
      public? true
    end
  end
end
