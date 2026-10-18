defmodule KilnCMS.CMS.Preparations.MaskUnreadableReferences do
  @moduledoc """
  Leaves the `:reference` snapshots the actor could not read directly out of
  every content record a read returns (`KilnCMS.CMS.ReferenceSnapshots`).

  `custom_fields` is a public attribute, so JSON:API, GraphQL and the public
  site serve it as read. A `:reference` value stores its target's id, slug
  and title as they were when the referrer was saved, a draft's included,
  and so a published post told an anonymous caller about a draft it linked
  to. This applies the both-ends rule `ContentLink` already enforces on the
  edges (`KilnCMS.CMS.Checks.LinkEndsReadable`) to the snapshot: a target is
  shown only when the actor may read it, through the target type's own read
  policy.

  Declared on the resource's top-level `preparations`, so it runs on every
  read action, relationship loads included. Skipped — the value is returned
  whole — when masking could never hide anything or could feed a write:

    * `authorize?: false` reads (firing, workers, internal plumbing);
    * a `KilnCMS.SystemActor` (its reads feed system writes, which must
      round-trip the stored value);
    * an editor or admin of the org (`Scoping.effective_tier/2`): they read
      every document of their site, and theirs are the reads an edit form is
      built from.

  So a masked value only ever reaches a reader who cannot write it back. The
  stored value is never changed. The cost is one `id in ^ids` read per
  content resource per read that returned a snapshot, none otherwise.
  """
  use Ash.Resource.Preparation

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.Checks.LinkEndsReadable
  alias KilnCMS.CMS.ReferenceSnapshots

  @impl true
  def prepare(query, _opts, context) do
    if mask?(query, context) do
      Ash.Query.after_action(query, fn query, records ->
        {:ok, mask(records, context.actor, query.tenant)}
      end)
    else
      query
    end
  end

  # authorize?: false — a match on the read's own flag, not a bypass: such a
  # read is internal plumbing whose result may be written back.
  defp mask?(_query, %{authorize?: false}), do: false
  defp mask?(_query, %{actor: %KilnCMS.SystemActor{}}), do: false

  defp mask?(query, %{actor: actor}),
    do: Scoping.effective_tier(actor, query) not in [:editor, :admin]

  # The targets are read under the read's own tenant: a content read is
  # tenant-scoped (epic #336), and `org_id` is not selected when the caller
  # did not ask for it (GraphQL selects only the requested fields).
  defp mask(records, actor, tenant) do
    case records |> Enum.flat_map(&ReferenceSnapshots.ids(Map.get(&1, :custom_fields))) do
      [] ->
        records

      ids ->
        readable = LinkEndsReadable.readable_ids(actor, Accounts.org_id(tenant), Enum.uniq(ids))
        Enum.map(records, &mask_record(&1, readable))
    end
  end

  # `mask/2` passes an unselected attribute (`%Ash.NotLoaded{}`) through.
  defp mask_record(%{custom_fields: custom_fields} = record, readable),
    do: %{record | custom_fields: ReferenceSnapshots.mask(custom_fields, readable)}

  defp mask_record(record, _readable), do: record
end
