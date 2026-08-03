defmodule KilnCMS.CMS.Changes.BustCodeInjection do
  @moduledoc """
  Invalidates a site's cached `%KilnCMS.CodeInjection{}` after any write (#490),
  so a settings save is visible on the next request instead of waiting out the
  TTL.

  This matters more here than for branding: the struct carries the CSP sources
  as well as the HTML, so a stale cache does not merely show the old snippet —
  it serves the *new* snippet under the *old* policy, which is a blocked script
  and a console error rather than a visibly out-of-date page.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      KilnCMS.Cache.bust_code_injection(record.org_id)
      {:ok, record}
    end)
  end
end
