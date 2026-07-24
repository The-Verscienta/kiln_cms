defmodule KilnCMS.CMS.Changes.BustFormCache do
  @moduledoc """
  Clears the published-delivery cache after a *publish-relevant* form (or
  form-field) write. A form may be embedded on any number of published pages
  via the `:form` block — the blast radius isn't a single `{type, slug}` — so a
  relevant change uses `Cache.bust_published/0`, the documented wide-radius
  invalidation (same stance as media edits).

  Only *active* forms actually render on published pages, and the visual
  builder now autosaves on every keystroke — so busting on every field/settings
  edit of a draft form would clear the whole site cache dozens of times for
  content that appears nowhere. We therefore skip the bust unless the form is
  active (a field write checks its parent form), still busting on the
  activate/deactivate toggle so a form appearing or disappearing invalidates.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.{Form, FormField}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      if should_bust?(changeset, record), do: KilnCMS.Cache.bust_published()
      {:ok, record}
    end)
  end

  # A form is publish-relevant when it's active now, or its active flag is
  # toggling (deactivating a live form must invalidate too).
  defp should_bust?(changeset, %Form{active: active}) do
    active or Ash.Changeset.changing_attribute?(changeset, :active)
  end

  # A field only affects published pages when its parent form is active. One
  # indexed primary-key read is far cheaper than the full cache clear (and the
  # cold-cache storm) it guards.
  defp should_bust?(_changeset, %FormField{form_id: form_id, org_id: org_id}) do
    case KilnCMS.CMS.get_form(form_id, authorize?: false, tenant: org_id) do
      {:ok, %Form{active: active}} -> active
      # Form gone (cascade delete) or unreadable — bust to be safe.
      _ -> true
    end
  end

  defp should_bust?(_changeset, _record), do: true
end
