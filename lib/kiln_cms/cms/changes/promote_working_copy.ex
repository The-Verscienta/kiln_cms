defmodule KilnCMS.CMS.Changes.PromoteWorkingCopy do
  @moduledoc """
  The write behind `:publish_changes` (docs/working-copy.md): moves the whole
  working copy into the live columns and clears it — the title and body, every
  held field in `working_fields`, and the held tags and related content
  (#1815). See `KilnCMS.CMS.WorkingCopy` for which fields those are.

  The rest of the action is what makes that a *publish* rather than an edit —
  the search text, embedding, artifacts, the `updated` webhook, the slug
  redirect for a held rename and the `published_version_id` pointer all move
  with it, and the slug, path-alias and URL validations judge the held values
  again (a slug free when it was saved may have been taken since). What
  deliberately does **not** move is `published_at`, and no workflow email goes
  out: the same date, no notification. A correction inside a live entry is not
  the entry going out.

  Applied at changeset-build time rather than in a `before_action`, so the
  action's plain `validate`s — the alt-text and claim gates, keyed on
  `changing(:blocks)` — judge the content that is about to go live, the way
  they do on `:update`. That reads the working copy off `changeset.data`, which
  the action's `optimistic_lock` guarantees is the row: a struct that predates
  the latest save fails the lock instead of publishing yesterday's draft.

  Held `custom_fields` go back through the field registry
  (`ApplyCustomFields.apply_restored/2`) at promotion, so a definition removed
  since the save does not come back to life on the public API.

  A record with no working copy is refused here with a field error as well as
  at the row (`change filter`): the row filter is the race guard, this is the
  message.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.WorkingCopy

  @impl true
  def change(changeset, _opts, context) do
    case changeset.data do
      %{working_copy_at: %DateTime{}, working_title: title, working_blocks: blocks} = data ->
        %{attributes: attributes, relationships: relationships} = WorkingCopy.promotion(data)

        changeset
        |> Ash.Changeset.force_change_attribute(:title, title)
        |> Ash.Changeset.force_change_attribute(:blocks, blocks || [])
        |> promote_attributes(attributes, context)
        |> promote_relationships(relationships)
        |> clear()

      _no_working_copy ->
        Ash.Changeset.add_error(changeset,
          field: :working_copy_at,
          message: "has no unpublished changes to publish"
        )
    end
  end

  @doc false
  # Shared with `FoldWorkingCopy`, which lands the same copy on a record that is
  # leaving `:published`.
  def promote_attributes(changeset, attributes, context) do
    changeset =
      Enum.reduce(attributes, changeset, fn {name, value}, acc ->
        Ash.Changeset.force_change_attribute(acc, name, value)
      end)

    if List.keymember?(attributes, :custom_fields, 0),
      do: KilnCMS.CMS.Changes.ApplyCustomFields.apply_restored(changeset, context),
      else: changeset
  end

  @doc false
  def promote_relationships(changeset, relationships) do
    Enum.reduce(relationships, changeset, fn {relationship, ids}, acc ->
      Ash.Changeset.manage_relationship(acc, relationship, ids, type: :append_and_remove)
    end)
  end

  @doc false
  def clear(changeset) do
    changeset
    |> Ash.Changeset.force_change_attribute(:working_title, nil)
    |> Ash.Changeset.force_change_attribute(:working_blocks, [])
    |> Ash.Changeset.force_change_attribute(:working_fields, %{})
    |> Ash.Changeset.force_change_attribute(:working_copy_at, nil)
  end
end
