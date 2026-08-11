defmodule KilnCMS.CMS.Changes.HashInlineScripts do
  @moduledoc """
  Derives `script_hashes` from the snippet on every write (#490).

  A CSP `'sha256-…'` source authorizes exactly one inline script body, so the
  list has to be a **function of the HTML** and never an input. Two things
  follow, and both are the reason this is a change rather than an accepted
  attribute:

    * A caller cannot authorize a script the snippet does not contain. The
      column is `writable? false`, so the only way a hash reaches the CSP is by
      the corresponding `<script>` being in the saved HTML.
    * It cannot drift. Editing one field without re-hashing the other would
      leave that field's script served but no longer authorized — silently, and
      looking exactly like the CSP being broken.

  ## Why it reads the stored row

  `:save` is an **upsert**, so a save that sends only `footer_html` produces a
  changeset in which `head_html` is simply absent — while `upsert_fields` leaves
  the stored head untouched. Hashing the changeset alone would then drop the
  head's hash and keep serving its script: blocked, with a console error as the
  only symptom. Hashing has to see the *resulting* row, so an unchanged field is
  read back rather than assumed nil.

  That is one extra read per write. Writes here are an admin saving a settings
  form, so it costs nothing that matters, and the alternative is a silent
  misconfiguration on the exact path this feature is used from.
  """
  use Ash.Resource.Change

  alias KilnCMS.CodeInjection

  @fields [:head_html, :footer_html]

  @impl true
  def change(changeset, _opts, _context) do
    stored = stored_row(changeset)
    values = Enum.map(@fields, &resulting(changeset, stored, &1))

    Ash.Changeset.force_change_attribute(
      changeset,
      :script_hashes,
      CodeInjection.inline_hashes(values)
    )
  end

  defp resulting(changeset, stored, field) do
    if Ash.Changeset.changing_attribute?(changeset, field) do
      Ash.Changeset.get_attribute(changeset, field)
    else
      stored && Map.get(stored, field)
    end
  end

  # `changeset.data` is an empty struct on the upsert path (it is a create), so
  # the stored row has to be read. Skipped entirely when both fields are being
  # written, which is what the settings form always does — the read is the cost
  # of a partial save, not of every save.
  defp stored_row(changeset) do
    if Enum.all?(@fields, &Ash.Changeset.changing_attribute?(changeset, &1)) do
      nil
    else
      read_row(changeset)
    end
  end

  defp read_row(changeset) do
    case changeset.data do
      %{id: id} when not is_nil(id) ->
        changeset.data

      _new ->
        KilnCMS.CMS.list_site_code_injection!(
          authorize?: false,
          tenant: Ash.Changeset.get_attribute(changeset, :org_id)
        )
        |> List.first()
    end
  rescue
    # A hashing pass that cannot read is not a reason to fail the save; the
    # worst case is a hash list derived from what was submitted, which is the
    # pre-existing behaviour and still fails closed (a blocked script, never an
    # authorized one that isn't there).
    _error -> nil
  end
end
