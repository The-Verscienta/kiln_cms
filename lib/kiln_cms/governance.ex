defmodule KilnCMS.Governance do
  @moduledoc """
  Read model for the **compliance & governance dashboard** (#352) — the visible
  home for the compliance cluster. Assembles, per content item, the editorial
  **version timeline** (PaperTrail: what changed, when), the linked **consents**
  (#356), and the **publish points** that back point-in-time delivery (#338).

  Read-only and admin-facing: the dashboard route is admin-gated. No data is
  mutated here.

  ## Who the reads run as (#1659)

  The governance subsystem's own bookkeeping (anchors, checkpoints and their
  entries) and the entitlement trail are read as `system/0`, a
  `KilnCMS.SystemActor` admitted by name on each of those resources. See
  `docs/policy-matrix.md`, "The system actor".

  Three kinds of read stay `authorize?: false` on purpose, each with its reason
  at the call site. A system-actor grant there would be a *standing* read for
  every system caller, which is wider than the one dashboard it serves (the
  #1402 argument):

    * **content** (`content_index/2`, `trail/3`) would hand system code the
      whole corpus, drafts included;
    * **`Accounts.User`** (display names) would be a grant over every account
      on the deployment;
    * **consents and version rows** are the compliance and editorial history
      itself (the `PointInTime` argument).

  Content, consent and version-row reads are tenant-scoped. `Accounts.User` is
  global, so those two reads take no tenant: they are bounded only by the ids
  on this org's own event and version rows. All of them are reached only from
  the admin-gated dashboard.
  """
  require Ash.Query

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing.PointInTime
  alias KilnCMS.Governance.Checkpoint
  alias KilnCMS.Governance.Witness

  # See `with_actor/2`.
  @actor_override {__MODULE__, :actor_override}

  @doc """
  The actor the governance subsystem's own bookkeeping runs as (#1659): the
  anchor chain, checkpoint minting and witness publication, and the
  dashboard's read of the entitlement trail.

  A `KilnCMS.SystemActor`, admitted by name on `CMS.HistoryAnchor`,
  `CMS.ChainCheckpoint`, `CMS.ChainCheckpointEntry` and
  `Billing.MembershipEvent` (see `docs/policy-matrix.md`, "The system actor"),
  rather than `authorize?: false`, which would skip every policy on them.
  """
  @spec system() :: KilnCMS.SystemActor.t() | nil
  def system do
    case Process.get(@actor_override, :unset) do
      :unset -> KilnCMS.SystemActor.new(:governance)
      actor -> actor
    end
  end

  @doc false
  # Test seam (#1659): run `fun` with `system/0` answering `actor` in this
  # process. It exists so a test can take the grant away and prove that every
  # governance read fails CLOSED (raises) rather than filtering to `[]`, which
  # is how a refused read answers. Process-local, and nothing on a request path
  # calls it; code that could call it could equally pass any actor it liked.
  @spec with_actor(term(), (-> result)) :: result when result: term()
  def with_actor(actor, fun) do
    previous = Process.get(@actor_override, :unset)
    Process.put(@actor_override, actor)

    try do
      fun.()
    after
      if previous == :unset,
        do: Process.delete(@actor_override),
        else: Process.put(@actor_override, previous)
    end
  end

  @typedoc "One entry in a document's version timeline."
  @type event :: %{
          action: atom(),
          at: DateTime.t(),
          changed: [String.t()],
          publish?: boolean(),
          actor: String.t() | nil,
          position: pos_integer()
        }

  @typedoc """
  One state transition on a document's trail (#1928). `chain` is
  `t:KilnCMS.Governance.Chain.verdict/0` for this version, or `:unattested`
  when it is anchored past the attested prefix. `propagation` is nil when no
  record matched, and `propagation_missing` then says why (`missing_reason/4`).
  `as_of_url` is nil on a restore, which point-in-time delivery does not model.
  """
  @type transition :: %{
          at: DateTime.t(),
          action: atom(),
          kind: :publish | :withdraw,
          position: pos_integer(),
          scheduled?: boolean(),
          approver: String.t() | nil,
          as_of_url: String.t() | nil,
          chain: atom() | {:tampered, String.t()},
          propagation: map() | nil,
          propagation_missing: :not_measured | :not_live | :pruned | :unrecorded | nil
        }

  @doc """
  Recent entitlement changes for a site, newest first (#337 Phase 2).

  Every paid-membership transition and the **audience delta it caused**, with the
  provider event or the admin that caused it. This is what makes "every
  entitlement change is visible in the governance audit trail" true rather than
  nominal: `KilnCMS.Billing.MembershipEvent` rows exist regardless, but nothing
  would surface them without a read here.

  Returns maps: `%{at, kind, from_status, to_status, added, removed, member,
  tier, provider_event_id, actor}`. Read as `system/0`; the routes that call it
  are admin-gated.

  **Fails closed.** The read runs with `authorize_with: :error`, so a lost grant
  raises instead of filtering to `[]`. An audit trail that silently reads empty
  looks exactly like a site where nothing changed.
  """
  @spec entitlement_index(Ash.UUID.t(), pos_integer()) :: [map()]
  def entitlement_index(org_id, limit \\ 100) do
    # Not `Billing.recent_membership_events!/1`: `:recent` prepares its own
    # `limit: 100`, and preparations run after an interface's `query:` options,
    # so the caller's `limit` would be ignored. Limiting after `for_read` wins.
    events =
      KilnCMS.Billing.MembershipEvent
      |> Ash.Query.for_read(:recent, %{}, actor: system(), tenant: org_id)
      |> Ash.Query.limit(limit)
      |> Ash.read!(authorize_with: :error)

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
      # authorize?: false — display names for the admin-gated dashboard.
      # `Accounts.User`'s read policy is self-only, and a system-actor grant
      # there would be a standing read over every account on the deployment,
      # the case #1402 refused. The ids come from this org's own event rows.
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
      # Tier names are public (`MembershipTier`'s read policy is
      # `authorize_if always()`), so this read needs no grant of its own. It
      # still fails closed: if that policy is ever tightened, a refused read
      # raises rather than blanking every tier on the trail.
      KilnCMS.Billing.list_tiers!(
        actor: system(),
        authorize_with: :error,
        tenant: org_id,
        query: [filter: [id: [in: ids]]]
      )
      |> Map.new(&{&1.id, &1.name})
    end
  end

  @typedoc "The witness panel's read model — see `witness_status/1`."
  @type witness_status :: %{
          checkpointing?: boolean(),
          witnessing?: boolean(),
          adapter: String.t(),
          latest: map() | nil,
          unwitnessed_count: non_neg_integer(),
          more_unwitnessed?: boolean(),
          oldest_unwitnessed: map() | nil,
          error: %{sequence: pos_integer(), message: String.t()} | nil
        }

  # A bound on the backlog read. Enough to distinguish "one retry pending" from
  # "this has been broken for a while"; past it the panel says "50+" rather than
  # loading a year of rows to be precise about a number nobody acts on.
  @backlog_probe 51
  @backlog_display 50

  @doc """
  Whether this site's history is actually being witnessed, and what the sink
  last said about it (#731).

  `chain_checkpoints.witness_error` is written on every failed publication and
  was surfaced nowhere: the only way to learn that a deployment had been
  silently unwitnessed for weeks was `mix kiln.audit.checkpoint`, or a log line
  from whenever it started. A healthy dashboard and an unwitnessed one looked
  identical, which is the failure `KilnCMS.Governance.Chain`'s moduledoc warns
  about — an operator infers from a green page that the witness is working.

  Two switches, reported separately, because they fail differently and an
  operator's next move is not the same:

    * `checkpointing?` — the kill switch. Off means no checkpoints are being
      minted at all, so there is nothing to publish.
    * `witnessing?` — whether a real sink is configured. Off is a deliberate
      single-machine posture (checkpoints stay in the database), not a fault.

  **The backlog is counted either way.** Gating it on `witnessing?` looks like
  the tidy thing to do and quietly rebuilds the hole this closes: an
  unrecognised `KILN_GOVERNANCE_WITNESS` falls back to `None` with a warning
  that only reaches stderr, so a one-character typo would present a real outage
  as a deliberate posture — a dashboard that reads exactly as healthy. The count
  is reported whichever way the switch resolves; only its *tone* depends on
  whether anything actually refused.
  """
  @spec witness_status(Ash.UUID.t()) :: witness_status()
  def witness_status(org_id) do
    unwitnessed = Checkpoint.unwitnessed(org_id, @backlog_probe)
    counted = Enum.take(unwitnessed, @backlog_display)

    %{
      checkpointing?: Checkpoint.enabled?(),
      witnessing?: Witness.enabled?(),
      adapter: adapter_description(),
      latest: describe_checkpoint(Checkpoint.latest(org_id)),
      unwitnessed_count: length(counted),
      more_unwitnessed?: length(unwitnessed) > @backlog_display,
      # The oldest, not the newest: it dates the outage. "Unpublished since
      # Tuesday" is actionable in a way that "3 unpublished" is not.
      oldest_unwitnessed: describe_checkpoint(List.first(unwitnessed)),
      # The oldest one that actually carries an error, which is not necessarily
      # the oldest one outstanding: a backlog from before a sink was configured
      # has no error at all, and printing the *newest* failure under the oldest
      # one's date attributes last night's 403 to a checkpoint from February.
      error: first_error(unwitnessed)
    }
  end

  # `KilnCMS.Governance.Witness.describe/0` owns the dispatch — resolving the
  # adapter here too would let a guard added there silently not apply to the
  # dashboard. What is added is the guard against the module itself: `describe/0`
  # is a callback on a module named in operator config, so a release missing it,
  # or a custom sink that implements the publishing callbacks but not this one,
  # would raise out of `handle_params`. The panel exists to report a broken
  # witness; a broken witness must not take the whole dashboard down with it.
  defp adapter_description do
    adapter = Witness.adapter()

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :describe, 0) do
      Witness.describe()
    else
      "#{inspect(adapter)} (this adapter does not describe itself)"
    end
  rescue
    error -> "#{inspect(Witness.adapter())} (unavailable: #{Exception.message(error)})"
  end

  defp first_error(checkpoints) do
    Enum.find_value(checkpoints, fn checkpoint ->
      case checkpoint.witness_error do
        error when is_binary(error) -> %{sequence: checkpoint.sequence, message: error}
        _none -> nil
      end
    end)
  end

  defp describe_checkpoint(nil), do: nil

  defp describe_checkpoint(checkpoint) do
    %{
      sequence: checkpoint.sequence,
      covered_at: checkpoint.covered_at,
      document_count: checkpoint.document_count,
      witness: checkpoint.witness,
      witnessed_at: checkpoint.witnessed_at,
      witness_error: checkpoint.witness_error
    }
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
        # authorize?: false — a content read stays a bypass rather than becoming a
        # system-actor grant, which would hand every system caller the whole corpus,
        # drafts included (#1402). The caller is the admin-gated dashboard, and the
        # read is tenant-scoped and metadata-only.
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

        # authorize?: false — a content read, as in `content_index/2` above: a
        # system grant would hand every system caller the corpus, drafts
        # included; this is tenant-scoped for the admin-gated dashboard.
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
        lost_retractions: [map],     # KilnCMS.Webhooks.lost_retractions/3 (#1926)
        publishes: [DateTime],       # publish points, newest first (for #338 links)
        transitions: [transition],   # one row per state transition, newest first (#1928)
        chain: verdict,              # KilnCMS.Governance.Chain.verdict/0
        chain_gap: attested_gap,     # how far attestation reaches (#811)
        chain_gap_range: %{attested, next, head} | nil,   # the same, for display
        predates_fold_order?: boolean,  # chain COULD have hit the #598 false-tamper bug (#1058)
        consents: [%KilnCMS.CMS.Consent{}]}

  `predates_fold_order?` is a sibling fact, never a softener: it says nothing
  about whether `chain` above is accurate, only whether the chain's anchors
  were folded in an order assigned at write time (#598) or inferred from a
  timestamp — the distinction that decides whether a `{:tampered, …}` verdict
  on this document could be the ordering bug rather than real tampering. See
  `KilnCMS.Governance.Chain.predates_fold_order?/1` and #1058.
  """
  @spec trail(String.t(), Ash.UUID.t(), Ash.UUID.t()) :: map() | nil
  def trail(type, id, org_id) do
    # Scoped to the request's site (epic #336): the type resolves, the record
    # loads, and the version timeline reads all under `org_id`, so an admin on
    # one site's host can never pull another org's content or audit trail by id.
    with ct when not is_nil(ct) <- ContentTypes.get(type, org_id),
         resource = storage_resource(ct),
         record when not is_nil(record) <- get_record(resource, id, org_id),
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

      item = %{
        type: to_string(ct.type),
        id: record.id,
        title: record.title,
        slug: record.slug,
        state: record.state,
        org_id: record.org_id,
        published_at: Map.get(record, :published_at),
        # In the trash (soft-deleted). Still has a trail: a `deleted`
        # retraction that never reached a consumer is reported here (#1926).
        trashed?: not is_nil(Map.get(record, :archived_at)),
        # Whether this item lives on the shared entry tier (D17). Point-in-time
        # delivery (#338) covers dynamic types now, so this no longer gates
        # the "view as of then" links — it stays as trail metadata.
        dynamic?: ct.source == :dynamic
      }

      # Tamper-evidence (#356): does the anchored history still reproduce the
      # signed chain hash minted at the last publish? One key resolution for
      # the whole verification, not one per anchor signature checked (#643).
      chain =
        KilnCMS.Provenance.KeyRegistry.with_cache(fn ->
          KilnCMS.Governance.Chain.verify_loaded(versions, storage, id, record.org_id)
        end)

      gap = KilnCMS.Governance.Chain.attested_gap(anchors)

      %{
        item: item,
        timeline: timeline,
        # Retraction webhooks (`unpublished` / `archived` / `deleted`) that
        # exhausted their retries for this document (#1926): a consumer that
        # may still be serving what the site withdrew. Keyed on the PUBLIC type
        # name, which is the event namespace. Read by the webhook subsystem,
        # whose ledger it is.
        lost_retractions:
          KilnCMS.Webhooks.lost_retractions(to_string(ct.type), record.id, record.org_id),
        publishes: for(e <- timeline, e.publish?, do: e.at),
        # One row per state transition with what became of it on the delivery
        # path (#1928): its approver, its propagation record, its `?as_of=`
        # link and whether the chain vouches for it. Keyed on the PUBLIC type
        # name, the event namespace the records were opened under.
        transitions:
          transitions(
            timeline,
            KilnCMS.Propagation.for_document(to_string(ct.type), record.id, record.org_id),
            %{verdict: chain, gap: gap, head: anchor},
            item
          ),
        chain: chain,
        # How far the ATTESTED prefix reaches (#811). A chain can have anchors
        # that verify and a newer one that does not, in which case `chain` above
        # reads `:unsigned`/`:unverifiable` — and calling that "history intact"
        # claims more than is known, because versions past the attested prefix
        # are anchored by a row nothing attests.
        chain_gap: gap,
        # The same fact pre-resolved for rendering: `%{attested, next, head}` or
        # nil. Done here, in plain Elixir, because a function component that
        # pattern-matches the `{:gap, …}` tuple inside HEEx is opaque enough that
        # dialyzer cannot see the clause is reachable.
        chain_gap_range:
          case gap do
            {:gap, attested, head} -> %{attested: attested, next: attested + 1, head: head}
            _no_gap -> nil
          end,
        # Whether this chain could have hit the pre-#598 false-tamper bug
        # (#1058): does NOT change `chain` above, only whether a red verdict on
        # it is worth investigating first. Reuses the anchors already loaded for
        # the gap and boundary reads — no second query.
        predates_fold_order?: KilnCMS.Governance.Chain.predates_fold_order?(anchors),
        # Edits since the last anchor — covered at the next publish.
        unanchored_tail: KilnCMS.Governance.Chain.unanchored_tail(versions, anchor),
        # Which checkpoint currently witnesses this document, and how strongly
        # (#731). Keyed on the STORAGE type for the reason the anchors are.
        witnessed: describe_witnessed(storage, id, record.org_id),
        # Scoped to the record's own site (epic #336) so the trail only shows
        # consents from the same org as the content.
        #
        # authorize?: false — consents are compliance records holding personal
        # data, so they get no standing system-actor read. The dashboard is
        # admin-gated.
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

  # `Checkpoint.witnessed_head/3`'s verdict, flattened for display (#731).
  #
  # Pre-resolved here rather than pattern-matched in HEEx, for the reason
  # `chain_gap_range` above is: a function component that destructures the tuple
  # inside a template is opaque enough that dialyzer cannot see the clause is
  # reachable.
  #
  # `:none` is deliberately not an error state. It is what a document younger
  # than the last checkpoint reads, and what every document reads on a
  # deployment with no witness configured — neither is a fault, and rendering
  # them as one would train an operator to ignore the panel that matters.
  defp describe_witnessed(storage, id, org_id) do
    case Checkpoint.witnessed_head(storage, id, org_id) do
      # A signature that demonstrably fails is `{:tampered, reason}` in the
      # ATTESTATION slot, not in place of the whole verdict — an entry that
      # checks out structurally can still be signed by a checkpoint whose own
      # signature does not verify. Folding it in with the healthy case renders a
      # tampered checkpoint green, which is the one thing this panel must never
      # do; `Checkpoint`'s `@type witnessed` omitted the tuple, which is how it
      # got written that way in the first place.
      {:ok, _entry, {:tampered, reason}} ->
        %{state: :tampered, reason: reason}

      {:ok, entry, attestation} ->
        %{
          state: :witnessed,
          sequence: entry.checkpoint_sequence,
          anchor_position: entry.head_sequence,
          attestation: attestation
        }

      :none ->
        %{state: :none}

      :unreadable ->
        %{state: :unreadable}

      {:tampered, reason} ->
        %{state: :tampered, reason: reason}
    end
  end

  # The record, or — when it is in the trash — the trashed record: AshArchival
  # filters soft-deleted rows out of every read but `:trashed`, and a trashed
  # document still has a trail (its versions, anchors and any `deleted`
  # retraction a consumer never received, #1926).
  defp get_record(resource, id, org_id) do
    # authorize?: false — a content read, so no system-actor grant (#1402, see
    # `content_index/2`); tenant-scoped, and the dashboard route is admin-gated.
    case Ash.get(resource, id, authorize?: false, tenant: org_id, error?: false) do
      {:ok, record} when not is_nil(record) -> record
      _missing -> get_trashed(resource, id, org_id)
    end
  end

  defp get_trashed(resource, id, org_id) do
    with action when not is_nil(action) <- Ash.Resource.Info.action(resource, :trashed),
         # authorize?: false — the same admin-gated content read as
         # `get_record/3`, through the one read AshArchival does not filter.
         {:ok, record} <-
           Ash.get(resource, id,
             action: :trashed,
             authorize?: false,
             tenant: org_id,
             error?: false
           ) do
      record
    else
      _missing -> nil
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
      # authorize?: false — display names, for the reason given in
      # `entitlement_names/1`. No standing system grant over `Accounts.User`.
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
      versions_asc
      |> Enum.with_index(1)
      |> Enum.map_reduce(%{}, fn {version, position}, last_known ->
        changes = version.changes || %{}

        event = %{
          action: version.version_action_name,
          # 1-based place in the fold order: what an anchor's `version_count`
          # counts, so a transition can be told apart as attested or not (#1928).
          position: position,
          at: version.version_inserted_at,
          actor: version.user_id && Map.get(actor_names, version.user_id),
          diffs:
            changes
            |> Enum.map(fn {field, new} -> {field, {Map.get(last_known, field), new}} end)
            |> Enum.sort_by(&elem(&1, 0)),
          publish?: version.version_action_name in PointInTime.publish_actions()
        }

        {event, Map.merge(last_known, changes)}
      end)

    Enum.reverse(events)
  end

  @doc """
  The point-in-time delivery URL (#338) for `item` at instant `at`: what the
  public API served for it then.
  """
  @spec as_of_url(map(), DateTime.t()) :: String.t()
  def as_of_url(item, %DateTime{} = at),
    do: "/api/content/#{item.type}/#{item.slug}?as_of=#{DateTime.to_iso8601(at)}"

  # Restoring a trashed document that was live when it was trashed puts it back
  # on the delivery path. It fires `restored`, not `published`, so it opens no
  # propagation record, and point-in-time delivery does not model it either.
  @restore_action :restore

  # The field a scheduled transition was set up through: whoever last set it
  # approved the transition the scheduler later ran.
  @schedule_fields %{
    publish_scheduled: "scheduled_at",
    unpublish_scheduled: "unpublish_at",
    archive_scheduled: "unpublish_at"
  }

  # A record is opened just after its transition's write commits, so its
  # `transitioned_at` trails the version's. The slack only absorbs clock
  # granularity; the upper bound is the next transition, whose record is its own.
  @match_slack_ms 1_000

  # One row per state transition, newest first (#1928): the approver, the
  # propagation record it opened (CDN purge and each webhook endpoint), its
  # `?as_of=` link and the chain's verdict on that version.
  #
  # Records carry no version id: the webhook fan-out opens them from the
  # event, after the write. Each transition takes the first unclaimed record
  # of its kind opened between its own write and the next transition's.
  defp transitions(timeline, records, chain, item) do
    events_asc = Enum.reverse(timeline)
    transitions_asc = transition_events(events_asc)
    # Each transition's successor bounds its record window; only its event matters.
    nexts = Enum.map(Enum.drop(transitions_asc, 1), &elem(&1, 0)) ++ [nil]

    {rows, _unclaimed} =
      transitions_asc
      |> Enum.zip(nexts)
      |> Enum.map_reduce(records, fn {{event, kind, was_live?}, next}, unclaimed ->
        restore? = event.action == @restore_action
        record = if not restore?, do: Enum.find(unclaimed, &claims?(&1, kind, event, next))

        row = %{
          at: event.at,
          action: event.action,
          kind: kind,
          position: event.position,
          scheduled?: Map.has_key?(@schedule_fields, event.action),
          approver: approver(event, events_asc),
          # Point-in-time delivery does not model a restore (see above), so a
          # link would answer "withdrawn" for a document readers could see.
          as_of_url: if(not restore?, do: as_of_url(item, event.at)),
          chain: row_verdict(event.position, chain),
          propagation: record && describe_propagation(record),
          propagation_missing:
            if(is_nil(record), do: missing_reason(event, kind, was_live?, DateTime.utc_now()))
        }

        {row, if(record, do: List.delete(unclaimed, record), else: unclaimed)}
      end)

    Enum.reverse(rows)
  end

  # The transitions among the versions, ascending, each as `{event, kind,
  # was_live?}`: whether the document was on the delivery path just before.
  # A restore counts only when the document was live as it went into the
  # trash; restoring a trashed draft puts nothing in front of readers.
  defp transition_events(events_asc) do
    {transitions, _state} =
      Enum.flat_map_reduce(events_asc, {false, false}, fn event, {live?, trashed_live?} ->
        case transition_kind(event.action) do
          :publish ->
            {[{event, :publish, live?}], {true, false}}

          :withdraw ->
            {[{event, :withdraw, live?}], {false, event.action == :destroy and live?}}

          nil when event.action == @restore_action and trashed_live? ->
            {[{event, :publish, live?}], {true, false}}

          nil ->
            {[], {live?, trashed_live?}}
        end
      end)

    transitions
  end

  defp transition_kind(action) do
    cond do
      action in PointInTime.publish_actions() -> :publish
      action in PointInTime.withdraw_actions() -> :withdraw
      true -> nil
    end
  end

  defp claims?(record, kind, event, next) do
    record.kind == kind and
      DateTime.diff(record.transitioned_at, event.at, :millisecond) >= -@match_slack_ms and
      (is_nil(next) or DateTime.compare(record.transitioned_at, next.at) == :lt)
  end

  # The admin who made the transition. A scheduled one runs as the scheduler,
  # so its approver is whoever last set the schedule it ran on.
  defp approver(event, events_asc) do
    case Map.fetch(@schedule_fields, event.action) do
      {:ok, field} ->
        events_asc
        |> Enum.take_while(&(&1.position < event.position))
        |> Enum.reverse()
        |> Enum.find(&sets?(&1, field))
        |> then(&(&1 && &1.actor))

      :error ->
        event.actor
    end
  end

  defp sets?(event, field),
    do: Enum.any?(event.diffs, &match?({^field, {_old, new}} when not is_nil(new), &1))

  @doc false
  # Why a transition has no propagation record. Public for its test.
  #
  #   * `:not_measured` — a restore, which opens none;
  #   * `:not_live` — a withdrawal of a document that was not live: nothing to
  #     take down, so nothing to measure;
  #   * `:pruned` — older than the records are kept;
  #   * `:unrecorded` — anything else: the transition predates propagation
  #     records (1.4), or its record could not be opened. Never "nothing was
  #     live": a publish always opens one.
  @spec missing_reason(map(), :publish | :withdraw, boolean(), DateTime.t()) ::
          :not_measured | :not_live | :pruned | :unrecorded
  def missing_reason(event, kind, was_live?, now) do
    cond do
      event.action == @restore_action -> :not_measured
      kind == :withdraw and not was_live? -> :not_live
      DateTime.diff(now, event.at, :day) >= KilnCMS.CMS.Propagation.retention_days() -> :pruned
      true -> :unrecorded
    end
  end

  # The record flattened for display and export: the CDN purge, then each
  # endpoint's delivery or terminal failure.
  #
  # The delivery ledger is pruned sooner than the records are (30 days against
  # 90, failed retractions kept), so `endpoints` can list fewer endpoints than
  # the transition went to: `endpoints_pruned` counts the missing ones, and
  # the settle-time `endpoint_latency_ms` / `endpoints_failed` still say how
  # they all fared.
  defp describe_propagation(record) do
    %{
      id: record.id,
      event: record.event,
      transitioned_at: record.transitioned_at,
      completed_at: record.completed_at,
      endpoint_latency_ms: record.endpoint_latency_ms,
      cdn_latency_ms: record.cdn_latency_ms,
      endpoints_expected: record.endpoints_expected,
      endpoints_failed: record.endpoints_failed,
      endpoints_pruned: max(record.endpoints_expected - length(record.deliveries), 0),
      # When the last endpoint answered, from the latency stamped at settle:
      # it outlives the deliveries it was measured from.
      all_delivered_at:
        record.endpoint_latency_ms &&
          DateTime.add(record.transitioned_at, record.endpoint_latency_ms, :millisecond),
      cdn: %{
        status: record.cdn_status,
        enqueued_at: record.cdn_enqueued_at,
        settled_at: record.cdn_settled_at
      },
      endpoints:
        Enum.map(record.deliveries, fn delivery ->
          %{
            url: delivery.endpoint_url,
            status: delivery.status,
            attempts: delivery.attempts,
            delivered_at: delivery.delivered_at,
            failed_at: KilnCMS.CMS.WebhookDelivery.given_up_at(delivery),
            # A later retraction of the document reached this endpoint after
            # all (#1926): the consumer was told, late.
            recovered_at: delivery.recovered_at,
            error: if(delivery.status == :failed, do: delivery.last_error)
          }
        end)
    }
  end

  @doc false
  # The chain's verdict on ONE version (#1928): the document's own verdict
  # while the version sits inside the attested prefix, and a weaker statement
  # past it. A tampered chain vouches for none of its rows. Public for its test.
  @spec row_verdict(pos_integer(), map()) :: atom()
  def row_verdict(_position, %{verdict: {:tampered, _reason}}), do: :tampered
  def row_verdict(_position, %{head: nil}), do: :unanchored

  def row_verdict(position, %{head: head}) when position > head.version_count,
    do: :unanchored

  def row_verdict(position, %{gap: {:gap, attested, _head}}) when position > attested,
    do: :unattested

  # Inside the attested prefix of a chain with a gap (#811): the document's
  # verdict is the weaker one its unattested head earns, but this version is
  # covered by an anchor whose signature verifies.
  def row_verdict(_position, %{gap: {:gap, _attested, _head}}), do: :verified
  def row_verdict(_position, %{verdict: verdict}), do: verdict
end
