defmodule KilnCMS.I18n.Changes.ApplySharedFields do
  @moduledoc """
  The body of a content resource's internal `:sync_shared_fields` action
  (#1327): force-changes the values `KilnCMS.I18n.SharedFields.plan/5`
  computed for one locale variant.

  The values ride in the changeset **context** (`shared_fields:`), not in an
  argument, so the action has no input any HTTP surface could fill; it is not
  routed anywhere either. Only the attributes a sync can produce are applied —
  the shareable record attributes, `custom_fields`, `blocks`, and the three
  working-copy columns a pending copy is kept in step with — and the two
  shareable relationships (#1859):

    * `tags: [tag_id]` — the whole tag set, through
      `manage_relationship(:tags, ids, type: :append_and_remove)`, the write
      `tag_ids` makes;
    * `related: [content_id]` — the whole related list, in order. Its
      `RelatedLink` rows are created and destroyed directly, and then
      numbered (`ContentLinks.order_related/2`). Not `manage_relationship`,
      which would look each target up as the actor: the `:localization`
      system actor reads content as an anonymous visitor does, so a draft
      target would fail the copy.

  Both run inside the action's transaction, so the row write, its version and
  the join writes land together or not at all. Anything else in the map is
  ignored.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentLinks
  alias KilnCMS.I18n.FieldLocalization

  @working_copy [:working_blocks, :working_fields, :working_base]

  @impl true
  def change(changeset, _opts, context) do
    allowed =
      FieldLocalization.shareable_attributes() ++ [:custom_fields, :blocks] ++ @working_copy

    shared = Map.get(changeset.context, :shared_fields, %{})

    shared
    |> Enum.filter(fn {name, _value} ->
      name in allowed and Ash.Resource.Info.attribute(changeset.resource, name)
    end)
    |> Enum.reduce(changeset, fn {name, value}, acc ->
      Ash.Changeset.force_change_attribute(acc, name, value)
    end)
    |> put_tags(Map.fetch(shared, :tags))
    |> put_related(Map.fetch(shared, :related), context)
  end

  defp put_tags(changeset, {:ok, ids}) when is_list(ids),
    do: Ash.Changeset.manage_relationship(changeset, :tags, ids, type: :append_and_remove)

  defp put_tags(changeset, _none), do: changeset

  defp put_related(changeset, {:ok, ids}, context) when is_list(ids) do
    ids = ids |> Enum.map(&to_string/1) |> Enum.uniq()

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      opts = [actor: context.actor, tenant: record.org_id]

      with :ok <- replace_related(record, ids, opts) do
        :ok = ContentLinks.order_related(record, ids)
        {:ok, record}
      end
    end)
  end

  defp put_related(changeset, _none, _context), do: changeset

  # The record's related rows become exactly `ids`: the ones it should no
  # longer hold destroyed, the missing ones created. Read failing closed, so
  # a refused read fails the copy rather than duplicating every link.
  defp replace_related(record, ids, opts) do
    with {:ok, current} <-
           CMS.list_related_links(
             Keyword.merge(opts,
               authorize_with: :error,
               query: [filter: [source_id: record.id], select: [:id, :target_id]]
             )
           ) do
      wanted = MapSet.new(ids)
      have = MapSet.new(current, &to_string(&1.target_id))

      removed =
        for link <- current, not MapSet.member?(wanted, to_string(link.target_id)), do: link

      added = for id <- ids, not MapSet.member?(have, id), do: id

      with :ok <- each(removed, &CMS.destroy_related_link(&1, opts)) do
        each(added, &CMS.create_related_link(%{source_id: record.id, target_id: &1}, opts))
      end
    end
  end

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:ok, _result} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
