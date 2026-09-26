defmodule KilnCMS.CMS.Changes.VerifySsoDomain do
  @moduledoc """
  Looks up a `KilnCMS.CMS.SiteSsoDomain`'s TXT record now, and stamps
  `verified_at` only if the record carries this row's token.

  A lookup that finds nothing is an error on the action, not a silent no-op, so
  the page can say what it looked for and where. It does **not** clear an
  earlier `verified_at` — the sign-in path re-checks DNS itself on every
  sign-in (`KilnCMS.Accounts.SiteSso.DomainCheck.published?/2`), so a stale
  stamp honours nothing on its own.

  The lookup runs while the changeset is built, not in a `before_action` hook:
  a hook runs inside the write's transaction, and a DNS query that takes its
  full timeout would hold a database connection for it.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.SiteSso.DomainCheck

  @impl true
  def change(changeset, _opts, _context) do
    %{domain: domain, verification_token: token} = changeset.data

    if DomainCheck.published?(domain, token) do
      Ash.Changeset.force_change_attribute(changeset, :verified_at, DateTime.utc_now())
    else
      Ash.Changeset.add_error(changeset,
        field: :domain,
        message:
          "no TXT record at #{DomainCheck.record_name(domain)} carries #{DomainCheck.record_value(token)} yet"
      )
    end
  end
end
