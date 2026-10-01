defmodule KilnCMS.CMS.Changes.FoldWorkingCopy do
  @moduledoc """
  Folds a pending working copy into the row when a live record leaves
  `:published` — `:unpublish`, `:archive` and their scheduled twins
  (docs/working-copy.md).

  A working copy is only meaningful next to a published text
  (`KilnCMS.CMS.WorkingCopy`). Once the record is a draft again there is
  nothing for it to run ahead of, and the author's latest words are the ones
  the draft should carry: the text that *was* live is not lost, it is the
  version `published_version_id` pointed at, restorable like any other.
  Discarding those edits instead would be the one path in the model that
  throws work away without being asked.

  The whole copy folds (#1815): the title and body, the held fields in
  `working_fields` and the held tags and related content, the same set
  `PromoteWorkingCopy` publishes. One exception: a held slug or path alias
  another record has claimed since it was saved is left at the live value
  rather than failing the transition — an unpublish has to happen.

  Runs in a `before_action`, and reads the row's own working copy under a row
  lock rather than trusting `changeset.data`: the retiring transitions carry no
  `optimistic_lock`, so the struct an editor unpublishes from may predate the
  autosave that landed a second ago. Declared BEFORE `SetSearchText` on each
  action, so the search column is rebuilt from the folded text.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias KilnCMS.CMS.Changes.PromoteWorkingCopy
  alias KilnCMS.CMS.Validations
  alias KilnCMS.CMS.WorkingCopy

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, &fold(&1, context))
  end

  defp fold(changeset, context) do
    case current_working_copy(changeset) do
      {:ok, %{working_copy_at: %DateTime{}} = row} ->
        %{attributes: attributes, relationships: relationships} =
          WorkingCopy.promotion(%{changeset.data | working_fields: row.working_fields})

        changeset
        |> adopt(row)
        |> Ash.Changeset.force_change_attribute(:title, row.working_title)
        |> Ash.Changeset.force_change_attribute(:blocks, row.working_blocks || [])
        |> PromoteWorkingCopy.promote_attributes(attributes, context)
        |> keep_address_if_taken(context)
        |> PromoteWorkingCopy.promote_relationships(relationships)
        |> PromoteWorkingCopy.clear()

      _none ->
        changeset
    end
  end

  # A held slug or path alias another record has claimed since it was saved
  # must not fail the transition: an unpublish has to happen, and the
  # scheduled twins have nobody to show an error to. The draft keeps its live
  # address instead; the editor can rename it again.
  defp keep_address_if_taken(changeset, context) do
    Enum.reduce(
      [{Validations.SlugAvailable, :slug}, {Validations.PathAliasValid, :path_alias}],
      changeset,
      fn {validation, attribute}, acc ->
        if Ash.Changeset.changing_attribute?(acc, attribute) and
             validation.validate(acc, [], context) != :ok do
          Ash.Changeset.force_change_attribute(acc, attribute, Map.get(acc.data, attribute))
        else
          acc
        end
      end
    )
  end

  # The caller's struct may predate the working copy entirely, and Ash drops a
  # change whose value equals what `changeset.data` already holds — so clearing
  # `working_copy_at` against a struct that never saw it set would write
  # nothing and leave the row's stamp in place. Bring the four columns on
  # `data` up to the row first, so the clears below register as changes.
  defp adopt(changeset, row) do
    data = %{
      changeset.data
      | working_title: row.working_title,
        working_blocks: row.working_blocks,
        working_fields: row.working_fields,
        working_copy_at: row.working_copy_at
    }

    %{changeset | data: data}
  end

  # `FOR UPDATE`, so a `:save_working_copy` racing this transition waits behind
  # it and then fails its own `state == :published` filter, rather than landing
  # between this read and the UPDATE that follows it.
  defp current_working_copy(%{data: %{id: id, org_id: org_id}, resource: resource}) do
    # authorize?: false — #1402's content-read argument: this is the row the
    # caller's own transition was already authorized to write, re-read under a
    # lock for four of its own columns, and nothing read leaves the changeset.
    # The transition's caller is often the AshOban scheduler
    # (`:archive_scheduled`), which has no read grant on content, and a
    # `SystemActor` content-read grant would hand every system caller the
    # whole corpus, drafts included.
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:working_title, :working_blocks, :working_fields, :working_copy_at])
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false, tenant: org_id)
  end
end
