defmodule KilnCMS.CMS.Changes.HashInlineScripts do
  @moduledoc """
  Derives `script_hashes` from the snippet on every write (#490).

  A CSP `'sha256-…'` source authorizes exactly one inline script body, so the
  list has to be a **function of the HTML** and never an input. Two things
  follow, and both are the reason this is a change rather than an accepted
  attribute:

    * A caller cannot authorize a script the snippet does not contain. The
      column is `writable? false`, so the only way a hash gets into the CSP is by
      the corresponding `<script>` being in the saved HTML.
    * It cannot drift. Editing `head_html` without touching the hash list would
      otherwise leave the old script authorized and the new one blocked —
      silently, and looking exactly like the CSP being broken.

  Recomputed from the **resulting** values rather than the changed ones: a save
  that only touches `footer_html` still has to re-hash both fields, or the head's
  hashes are dropped.
  """
  use Ash.Resource.Change

  alias KilnCMS.CodeInjection

  @impl true
  def change(changeset, _opts, _context) do
    head = Ash.Changeset.get_attribute(changeset, :head_html)
    footer = Ash.Changeset.get_attribute(changeset, :footer_html)

    Ash.Changeset.force_change_attribute(
      changeset,
      :script_hashes,
      CodeInjection.inline_hashes([head, footer])
    )
  end
end
