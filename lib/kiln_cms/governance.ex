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
          publish?: boolean(),
          actor: String.t() | nil
        }

  @doc """
  Recent entitlement changes for a site, newest first (#337 Phase 2).

  Every paid-membership transition and the **audience delta it caused**, with the
  provider event or the admin that caused it. This is what makes "every
  entitlement change is visible in the governance audit trail" true rather than
  nominal: `KilnCMS.Billing.MembershipEvent` rows exist regardless, but nothing
  would surface them without a read here.

  Returns maps: `%{at, kind, from_status, to_status, added, removed, member,
  tier, provider_event_id, actor}`. Read as the system, like the rest of this
  module; the routes that call it are admin-gated.
  """
  @spec entitlement_index(Ash.UUID.t(), pos_integer()) :: [map()]
  def entitlement_index(org_id, limit \\ 100) do
    events =
      KilnCMS.Billing.MembershipEvent
      |> Ash.Query.for_read(:recent, %{}, authorize?: false, tenant: org_id)
      |> Ash.Query.limit(limit)
      |> Ash.read!()

    names = entitlement_names(events)
    tiers = entitlement_tiers(events, org_id)

    Enum.map(events, fn event ->
      %{
        at: event.inserted_at,
        kind: event.kind,
        from_status: event.from_status,
        to_status: event.to_status,
        added: event.audiences_added,
        removed: event.audiences_removed,
        member: Map.get(names, event.user_id),
        tier: Map.get(tiers, event.tier_id),
        provider_event_id: event.provider_event_id,
        actor: Map.get(names, event.actor_id)
      }
    end)
  end

  # Members and comping admins in one lookup.
  defp entitlement_names(events) do
    ids =
      events
      |> Enum.flat_map(&[&1.user_id, &1.actor_id])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      KilnCMS.Accounts.User
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.id, &1.name || to_string(&1.email)})
    end
  end

  defp entitlement_tiers(events, org_id) do
    ids = events |> Enum.map(& &1.tier_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      KilnCMS.Billing.MembershipTier
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!(authorize?: false, tenant: org_id)
      |> Map.new(&{&1.id, &1.name})
    end
  end

  @doc """
  Recent governable content (compiled AND dynamic types), newest first — the
  dashboard index. Returns lightweight maps: `%{type, id, title, slug, state}`.
  """
  @spec content_index(Ash.UUID.t(), pos_integer()) :: [map()]
  def content_index(org_id, limit \\ 50) do
    # Scoped to the request's site (epic #336) so the governance dashboard only
    # lists the current org's content.
    compiled =
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

    compiled ++ dynamic_index(org_id, limit)
  end

  # Dynamic (D17) entries for the index: one read of the shared entry tier,
  # labeled with each entry's public type name. Entries whose definition no
  # longer resolves (archived between reads) are dropped — their trail page
  # couldn't resolve the type either.
  defp dynamic_index(org_id, limit) do
    case ContentTypes.dynamic_all(org_id) do
      [] ->
        []

      descriptors ->
        names = Map.new(descriptors, &{&1.definition.id, &1.type})

        KilnCMS.CMS.Entry
        |> Ash.Query.sort(updated_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!(authorize?: false, tenant: org_id)
        |> Enum.flat_map(&entry_row(&1, names))
    end
  end

  defp entry_row(record, names) do
    case names[record.type_definition_id] do
      nil ->
        []

      type ->
        [
          %{
            type: type,
            id: record.id,
            title: record.title,
            slug: record.slug,
            state: record.state
          }
        ]
    end
  end

  @doc """
  The governance trail for one content item, or `nil` if the type/id is unknown.

      %{item: %{type, id, title, slug, state, published_at},
        timeline: [event],           # newest first
        publishes: [DateTime],       # publish points, newest first (for #338 links)
        chain: verdict,              # KilnCMS.Governance.Chain.verdict/0
        chain_gap: attested_gap,     # how far attestation reaches (#811)
        chain_gap_range: %{attested, next, head} | nil,   # the same, for display
        consents: [%KilnCMS.CMS.Consent{}]}
  """
  @spec trail(String.t(), Ash.UUID.t(), Ash.UUID.t()) :: map() | nil
  def trail(type, id, org_id) do
    # Scoped to the request's site (epic #336): the type resolves, the record
    # loads, and the version timeline reads all under `org_id`, so an admin on
    # one site's host can never pull another org's content or audit trail by id.
    with ct when not is_nil(ct) <- ContentTypes.get(type, org_id),
         resource = storage_resource(ct),
         {:ok, record} when not is_nil(record) <-
           Ash.get(resource, id, authorize?: false, tenant: org_id, error?: false),
         true <- record_matches_type?(ct, record) do
      # One ascending versions read feeds BOTH the timeline and the chain
      # verification (which folds a prefix of the same list).
      versions = versions_asc(resource, id, org_id)
      # Anchors key on the STORAGE type (what the publish hook records) — the
      # generic :entry tier for dynamic types, not the public name.
      storage = to_string(ContentTypes.storage_type(ct))
      # One anchors read serves both the head (for `unanchored_tail/2`) and the
      # attestation reach (#811) — `latest_anchor/3` would have re-queried.
      anchors = KilnCMS.Governance.Chain.anchors(storage, id, record.org_id)
      anchor = List.first(anchors)
      timeline = timeline(versions, actor_names(versions))

      %{
        item: %{
          type: to_string(ct.type),
          id: record.id,
          title: record.title,
          slug: record.slug,
          state: record.state,
          org_id: record.org_id,
          published_at: Map.get(record, :published_at),
          # Whether this item lives on the shared entry tier (D17). Point-in-time
          # delivery (#338) covers dynamic types now, so this no longer gates
          # the "view as of then" links — it stays as trail metadata.
          dynamic?: ct.source == :dynamic
        },
        timeline: timeline,
        publishes: for(e <- timeline, e.publish?, do: e.at),
        # Tamper-evidence (#356): does the anchored history still reproduce the
        # signed chain hash minted at the last publish? One key resolution for
        # the whole verification, not one per anchor signature checked (#643).
        chain:
          KilnCMS.Provenance.KeyRegistry.with_cache(fn ->
            KilnCMS.Governance.Chain.verify_loaded(versions, storage, id, record.org_id)
          end),
        # How far the ATTESTED prefix reaches (#811). A chain can have anchors
        # that verify and a newer one that does not, in which case `chain` above
        # reads `:unsigned`/`:unverifiable` — and calling that "history intact"
        # claims more than is known, because versions past the attested prefix
        # are anchored by a row nothing attests.
        chain_gap: KilnCMS.Governance.Chain.attested_gap(anchors),
        # The same fact pre-resolved for rendering: `%{attested, next, head}` or
        # nil. Done here, in plain Elixir, because a function component that
        # pattern-matches the `{:gap, …}` tuple inside HEEx is opaque enough that
        # dialyzer cannot see the clause is reachable.
        chain_gap_range:
          case KilnCMS.Governance.Chain.attested_gap(anchors) do
            {:gap, attested, head} -> %{attested: attested, next: attested + 1, head: head}
            _no_gap -> nil
          end,
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

  # The table a type's records (and versions) live in: dynamic types share the
  # generic entry tier (D17), compiled types own their resource.
  defp storage_resource(%{source: :dynamic}), do: KilnCMS.CMS.Entry
  defp storage_resource(%{resource: resource}), do: resource

  # A dynamic type's trail must only serve entries of THAT type — the entry
  # tier is shared, so without this check an id of one dynamic type could be
  # read under another type's name.
  defp record_matches_type?(%{source: :dynamic, definition: definition}, record),
    do: record.type_definition_id == definition.id

  defp record_matches_type?(_ct, _record), do: true

  # A document's versions, ascending. Delegated rather than restated: this list
  # is folded by `Chain.verify_loaded/4`, so its order has to be the chain's own
  # definition of the fold order, not a second copy that can drift out of step
  # (#598). Tenant-scoped like every other read in `trail/3` (epic #336).
  defp versions_asc(resource, id, org_id) do
    KilnCMS.Governance.Chain.versions_asc(resource, id, org_id)
  end

  # "Who" (#352): resolve the versions' acting users to display names in one
  # read. Users are global (not org-scoped); a deleted account leaves a nil
  # `user_id` (nilified FK) and renders as unattributed.
  defp actor_names(versions) do
    ids = versions |> Enum.map(& &1.user_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      KilnCMS.Accounts.User
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.id, &1.name || to_string(&1.email)})
    end
  end

  # The PaperTrail version timeline, newest first: each version's action, time,
  # actor (when the write carried one), and the old → new value pair per
  # changed field (#352, `diffs` — the changed field names are its keys).
  # `:changes_only` tracking stores each version's NEW values; the "old" side
  # is the most recent earlier version's value for that field (nil when never
  # set before), accumulated in one ascending pass.
  defp timeline(versions_asc, actor_names) do
    {events, _last_known} =
      Enum.map_reduce(versions_asc, %{}, fn version, last_known ->
        changes = version.changes || %{}

        event = %{
          action: version.version_action_name,
          at: version.version_inserted_at,
          actor: version.user_id && Map.get(actor_names, version.user_id),
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
