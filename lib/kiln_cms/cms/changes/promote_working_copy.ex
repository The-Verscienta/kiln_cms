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

  ## The lost-update guard

  The copy records the live value each held key was based on
  (`working_base`; `KilnCMS.CMS.WorkingCopy.reconcile/1`). A key whose live
  value has changed since — an API `PATCH`, in-context editing — and that the
  copy also changed is a conflict, and is never promoted silently: the
  `resolve` argument decides it (`"mine"` / `"theirs"` per key, or `"*"`), and
  without a decision the publish is refused naming the keys. A key the copy
  never changed (the title carried along while only the body was edited)
  keeps whatever is live.

  A record with no working copy is refused here with a field error as well as
  at the row (`change filter`): the row filter is the race guard, this is the
  message.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.WorkingCopy

  @impl true
  def change(changeset, _opts, context) do
    case changeset.data do
      %{working_copy_at: %DateTime{}} = data ->
        resolve = resolutions(Ash.Changeset.get_argument(changeset, :resolve))

        case keys_to_promote(WorkingCopy.reconcile(data), resolve) do
          {:ok, keys} -> promote(changeset, data, keys, context)
          {:conflicts, keys} -> refuse(changeset, keys)
        end

      _no_working_copy ->
        Ash.Changeset.add_error(changeset,
          field: :working_copy_at,
          message: "has no unpublished changes to publish"
        )
    end
  end

  # The lost-update guard (`WorkingCopy.reconcile/1`). A conflicting key goes
  # live only on a decision: `"mine"` promotes the copy's value over the live
  # one, `"theirs"` keeps the live one and drops the copy's; `"*"` answers
  # every key not decided one by one. Undecided conflicts refuse the whole
  # publish. A release has nobody to ask, so it is refused too — `Releases`
  # reports the item as blocked before it gets here.
  defp keys_to_promote(%{promote: promote, conflicts: conflicts}, resolve) do
    case Enum.reject(conflicts, &choice(resolve, &1)) do
      [] -> {:ok, promote ++ Enum.filter(conflicts, &(choice(resolve, &1) == "mine"))}
      undecided -> {:conflicts, undecided}
    end
  end

  defp resolutions(%{} = resolve),
    do: Map.new(resolve, fn {key, choice} -> {to_string(key), to_string(choice)} end)

  defp resolutions(_none), do: %{}

  defp choice(resolve, key) do
    case Map.get(resolve, key) || Map.get(resolve, "*") do
      choice when choice in ["mine", "theirs"] -> choice
      _undecided -> nil
    end
  end

  defp promote(changeset, data, keys, context) do
    %{attributes: attributes, relationships: relationships} = WorkingCopy.promotion(data, keys)

    changeset
    |> promote_text(:title, "title" in keys, data.working_title)
    |> promote_text(:blocks, "blocks" in keys, data.working_blocks || [])
    |> promote_attributes(attributes, context)
    |> promote_relationships(relationships)
    |> clear()
  end

  defp promote_text(changeset, name, true, value),
    do: Ash.Changeset.force_change_attribute(changeset, name, value)

  defp promote_text(changeset, _name, false, _value), do: changeset

  defp refuse(changeset, keys) do
    Ash.Changeset.add_error(changeset,
      field: :working_copy_at,
      message:
        "conflicts with a change made on the live page after the draft was saved (%{fields})",
      vars: [fields: Enum.join(keys, ", ")]
    )
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
    |> Ash.Changeset.force_change_attribute(:working_base, %{})
    |> Ash.Changeset.force_change_attribute(:working_copy_at, nil)
  end
end
