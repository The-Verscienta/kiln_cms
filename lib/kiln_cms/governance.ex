defmodule KilnCMS.Governance do
  @moduledoc """
  Read model for the **compliance & governance dashboard** (#352) — the visible
  home for the compliance cluster. Assembles, per content item, the editorial
  **version timeline** (PaperTrail: what changed, when), the linked **consents**
  (#356), and the **publish points** that back point-in-time delivery (#338).

  Read-only and admin-facing: the dashboard route is admin-gated, so the trail is
  gathered as the system (`authorize?: false`). No data is mutated here.
  """
  require Ash.Query

  alias KilnCMS.CMS.ContentTypes

  @publish_actions [:publish, :publish_scheduled]

  @typedoc "One entry in a document's version timeline."
  @type event :: %{
          action: atom(),
          at: DateTime.t(),
          changed: [String.t()],
          publish?: boolean()
        }

  @doc """
  Recent governable content (compiled types), newest first — the dashboard index.
  Returns lightweight maps: `%{type, id, title, slug, state}`.
  """
  @spec content_index(pos_integer()) :: [map()]
  def content_index(org_id, limit \\ 50) do
    # Scoped to the request's site (epic #336) so the governance dashboard only
    # lists the current org's content.
    Enum.flat_map(ContentTypes.all(), fn ct ->
      ct.resource
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(limit)
      |> Ash.read!(authorize?: false, tenant: org_id)
      |> Enum.map(fn record ->
        %{
          type: to_string(ct.type),
          id: record.id,
          title: record.title,
          slug: record.slug,
          state: record.state
        }
      end)
    end)
  end

  @doc """
  The governance trail for one content item, or `nil` if the type/id is unknown.

      %{item: %{type, id, title, slug, state, published_at},
        timeline: [event],           # newest first
        publishes: [DateTime],       # publish points, newest first (for #338 links)
        consents: [%KilnCMS.CMS.Consent{}]}
  """
  @spec trail(String.t(), Ash.UUID.t(), Ash.UUID.t()) :: map() | nil
  def trail(type, id, org_id) do
    # Scoped to the request's site (epic #336): the type resolves, the record
    # loads, and the version timeline reads all under `org_id`, so an admin on
    # one site's host can never pull another org's content or audit trail by id.
    with ct when not is_nil(ct) <- ContentTypes.get(type, org_id),
         {:ok, record} when not is_nil(record) <-
           Ash.get(ct.resource, id, authorize?: false, tenant: org_id, error?: false) do
      # One ascending versions read feeds BOTH the timeline and the chain
      # verification (which folds a prefix of the same list).
      versions = versions_asc(ct.resource, id, org_id)
      # Anchors key on the STORAGE type (what the publish hook records) — the
      # generic :entry tier for dynamic types, not the public name.
      storage = to_string(ContentTypes.storage_type(ct))
      anchor = KilnCMS.Governance.Chain.latest_anchor(storage, id, record.org_id)
      timeline = timeline(versions)

      %{
        item: %{
          type: to_string(ct.type),
          id: record.id,
          title: record.title,
          slug: record.slug,
          state: record.state,
          org_id: record.org_id,
          published_at: Map.get(record, :published_at)
        },
        timeline: timeline,
        publishes: for(e <- timeline, e.publish?, do: e.at),
        # Tamper-evidence (#356): does the anchored history still reproduce the
        # signed chain hash minted at the last publish?
        chain: KilnCMS.Governance.Chain.verify_loaded(versions, storage, id, record.org_id),
        # Edits since the last anchor — covered at the next publish.
        unanchored_tail: KilnCMS.Governance.Chain.unanchored_tail(versions, anchor),
        # Scoped to the record's own site (epic #336) so the trail only shows
        # consents from the same org as the content.
        consents:
          KilnCMS.CMS.list_consents_for!(to_string(ct.type), id,
            authorize?: false,
            tenant: record.org_id
          )
      }
    else
      _ -> nil
    end
  end

  # A document's versions, ascending — the same order the chain folds in.
  # Tenant-scoped like every other read in `trail/3` (epic #336).
  defp versions_asc(resource, id, org_id) do
    Module.concat(resource, Version)
    |> Ash.Query.filter(version_source_id == ^id)
    |> Ash.Query.sort(version_inserted_at: :asc, id: :asc)
    |> Ash.read!(authorize?: false, tenant: org_id)
  end

  # The PaperTrail version timeline, newest first: each version's action, time,
  # and the old → new value pair per changed field (#352, `diffs` — the changed
  # field names are its keys). `:changes_only` tracking stores each version's
  # NEW values; the "old" side is the most recent earlier version's value for
  # that field (nil when never set before), accumulated in one ascending pass.
  defp timeline(versions_asc) do
    {events, _last_known} =
      Enum.map_reduce(versions_asc, %{}, fn version, last_known ->
        changes = version.changes || %{}

        event = %{
          action: version.version_action_name,
          at: version.version_inserted_at,
          diffs:
            changes
            |> Enum.map(fn {field, new} -> {field, {Map.get(last_known, field), new}} end)
            |> Enum.sort_by(&elem(&1, 0)),
          publish?: version.version_action_name in @publish_actions
        }

        {event, Map.merge(last_known, changes)}
      end)

    Enum.reverse(events)
  end
end
