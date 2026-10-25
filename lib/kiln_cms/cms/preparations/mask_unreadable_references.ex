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

  The same read answers each readable target's current slug and title, and
  every snapshot left in carries those instead of the copy stored when the
  referrer was saved (`ReferenceSnapshots.present/2`), so a renamed target
  is served under its new name without re-saving its referrers. The skipped
  reads above get the stored labels.
  """
  use Ash.Resource.Preparation

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.Checks.LinkEndsReadable
  alias KilnCMS.CMS.PreviewGrant
  alias KilnCMS.CMS.ReferenceSnapshots

  @impl true
  def prepare(query, _opts, context) do
    if mask?(query, context) do
      grant = PreviewGrant.from_context(query.context)

      Ash.Query.after_action(query, fn query, records ->
        {:ok, mask(records, context.actor, query.tenant, grant)}
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
  #
  # A preview grant on the read (#1887) is carried into the targets' read, as
  # `LinkEndsReadable` carries it into the edges' — a snapshot of the shared
  # draft is shown wherever the draft itself is.
  defp mask(records, actor, tenant, grant) do
    case records |> Enum.flat_map(&ReferenceSnapshots.ids(Map.get(&1, :custom_fields))) do
      [] ->
        records

      ids ->
        labels =
          LinkEndsReadable.readable_labels(actor, Accounts.org_id(tenant), Enum.uniq(ids), grant)

        Enum.map(records, &present_record(&1, labels))
    end
  end

  # `present/2` passes an unselected attribute (`%Ash.NotLoaded{}`) through.
  defp present_record(%{custom_fields: custom_fields} = record, labels),
    do: %{record | custom_fields: ReferenceSnapshots.present(custom_fields, labels)}

  defp present_record(record, _labels), do: record
end
