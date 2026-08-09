defmodule KilnCMS.CMS.Promotion do
  @moduledoc """
  Graduates an admin-defined **dynamic content type into a compiled one**
  (decision D17's "no dead end") — the data half of the promotion, run by
  `mix kiln.promote_data` after `mix kiln.gen.content --from <name>` has
  generated the compiled resource and its migration has been applied.

  In one transaction it:

    1. moves the type's entry rows into the compiled type's table (**ids are
       preserved**, so taggings and content links — both polymorphic by UUID —
       keep working with no changes);
    2. moves their PaperTrail versions into the compiled type's versions table;
    3. re-attests their tamper-evident history anchors under the compiled type,
       so `Chain.verify/4` still resolves the chain instead of orphaning it
       (#704 — anchors key on the document's type);
    4. deletes their fired `:entry` artifacts and stale reference edges (the
       artifact API backfills on demand under the new storage type);
    5. re-scopes the type's `FieldDefinition` rows to the compiled type, so
       every custom field keeps rendering and validating exactly as before;
    6. archives the `TypeDefinition` (restorable, but its name now belongs to
       the compiled type).

  Fields deliberately stay **data-driven** after promotion: the editor renders
  inputs from `FieldDefinition` rows, not from resource attributes, so
  promoting a field to a real column is a manual follow-up (add the attribute,
  migrate the JSONB key over, drop the definition) done per field when
  querying/indexing demands it.

  Row copying works on the **column intersection** of the two tables (from
  `information_schema`), so it is robust to shape differences (e.g. a target
  generated without `excerpt`) — columns only one side has are dropped or left
  at their defaults. `search_vector` is rebuilt by the target table's trigger
  on insert.
  """

  require Logger

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Governance.Checkpoint
  alias KilnCMS.Repo

  # Never copied: the type scope column is meaningless on a compiled table, and
  # search_vector is trigger-maintained per table.
  @excluded_columns ~w(type_definition_id search_vector)

  @doc """
  Promote dynamic type `name`'s data into its compiled successor.

  Options:

    * `:into` — the target compiled type (atom or name string). Defaults to
      `name` itself, i.e. the compiled type the generator created for it.

  Returns `{:ok, %{entries: n, versions: n}}` or raises on any inconsistency —
  the move runs in one transaction, so a failure moves nothing.

  Two things happen *after* that transaction commits and cannot roll it back:
  the delivery caches are busted, and a checkpoint is minted over the
  re-attested anchors (#849). A failure in either is logged, not raised, so a
  successful promotion is never reported as a failure.
  """
  @spec promote!(String.t(), keyword()) ::
          {:ok, %{entries: non_neg_integer(), versions: non_neg_integer()}}
  def promote!(name, opts \\ []) when is_binary(name) do
    definition = CMS.get_type_definition_by_name!(name, authorize?: false)

    target = ContentTypes.get(opts[:into] || name)

    unless target && target.source == :compiled do
      raise ArgumentError, """
      no compiled content type to promote #{inspect(name)} into.

      Generate it first (then apply its migration):

          mix kiln.gen.content --from #{name}
          mix ash.codegen add_#{name}s && mix ash.migrate
      """
    end

    target_table = table_for(target.resource)

    # `reattested` rides alongside the result rather than inside it: it decides
    # whether a checkpoint is worth minting, and is not something a caller of
    # `promote!/2` asked for — the returned map is a documented shape.
    {:ok, {result, reattested, notifications}} =
      Repo.transaction(fn ->
        entry_count = move_rows("entries", target_table, definition.id)
        version_count = move_versions(target_table)
        reattested = reattest_anchors(target_table, target, definition.org_id)
        purge_artifacts_and_edges()
        rescope_field_definitions(definition, target)
        notifications = archive_definition(definition)

        {%{entries: entry_count, versions: version_count}, reattested, notifications}
      end)

    # Dispatch the archive's Ash notifications now that the transaction
    # committed (holding them avoids the missed-notifications warning).
    Ash.Notifier.notify(notifications)

    # The type moved tiers: delivery must re-resolve it as compiled, and any
    # cached payloads/artifact bodies for it are stale. Bust the definition's own
    # site (epic #336).
    #
    # Before the checkpoint, deliberately. Minting reaches the witness sink, so
    # it is both slow (a PUT plus `confirm/5`'s read-back) and able to raise —
    # and the busts are what stop delivery serving a type whose rows have just
    # moved out from under it. Nothing about witnessing is worth delaying them.
    KilnCMS.Cache.bust_type_registry(definition.org_id)
    KilnCMS.Cache.bust_published()

    recheckpoint(reattested, definition.org_id)

    {:ok, result}
  end

  # ── row moves (SQL, column-intersection) ──────────────────────────────────

  # Interpolated identifiers, not data: `target_table` comes from the compiled
  # resource's AshPostgres config, `source_table` is the literal "entries", and
  # `columns` are quoted names read from information_schema — none are
  # request-derived (this runs from a dev-invoked mix task). Values are bound.
  # sobelow_skip ["SQL.Query"]
  defp move_rows(source_table, target_table, definition_id) do
    columns = shared_columns(source_table, target_table)

    %{num_rows: copied} =
      Repo.query!(
        """
        INSERT INTO #{target_table} (#{columns})
        SELECT #{columns} FROM #{source_table} WHERE type_definition_id = $1
        """,
        [Ecto.UUID.dump!(definition_id)]
      )

    %{num_rows: ^copied} =
      Repo.query!("DELETE FROM #{source_table} WHERE type_definition_id = $1", [
        Ecto.UUID.dump!(definition_id)
      ])

    copied
  end

  # Same identifier interpolation as move_rows — table from resource config,
  # columns from information_schema; nothing request-derived.
  # sobelow_skip ["SQL.Query"]
  defp move_versions(target_table) do
    versions_table = "#{target_table}_versions"
    columns = shared_columns("entries_versions", versions_table)

    # The entries were deleted above (same transaction), so select the moved
    # ids from their new home.
    %{num_rows: copied} =
      Repo.query!(
        """
        INSERT INTO #{versions_table} (#{columns})
        SELECT #{columns} FROM entries_versions
        WHERE version_source_id IN (SELECT id FROM #{target_table})
        """,
        []
      )

    %{num_rows: _deleted} =
      Repo.query!(
        """
        DELETE FROM entries_versions
        WHERE version_source_id IN (SELECT id FROM #{target_table})
        """,
        []
      )

    copied
  end

  # History anchors (#356) key on the document's public type — `"entry"` for a
  # dynamic doc, the compiled atom now — so the move orphans them unless they are
  # re-attested under the new type. Left orphaned, `Chain.verify/4` reads nothing
  # under the new type and the next publish silently re-anchors from genesis
  # (#704). Scope to docs that BOTH moved into the target AND still carry `entry`
  # anchors, so a re-promotion into a shared target skips docs already re-keyed —
  # same "no longer in entries / now in target" shape as `purge_artifacts_and_edges`.
  #
  # Same identifier-interpolation rationale as `move_rows`: `target_table` comes
  # from the compiled resource's config, the literals are constant, nothing is
  # request-derived. `Chain.repoint_after_promotion/4` re-signs each anchor under
  # the new type (see its docs for why a bare UPDATE can't).
  # sobelow_skip ["SQL.Query"]
  defp reattest_anchors(target_table, target, org_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT source_id FROM history_anchors
        WHERE resource_type = 'entry'
          AND org_id = $1
          AND source_id IN (SELECT id FROM #{target_table})
        """,
        [Ecto.UUID.dump!(org_id)]
      )

    source_ids = Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)

    KilnCMS.Governance.Chain.repoint_after_promotion(
      target.resource,
      source_ids,
      "entry",
      to_string(target.type),
      org_id
    )
  end

  # ── checkpoint coverage (#849) ────────────────────────────────────────────

  # Re-attesting the anchors moves them to a `resource_type` no checkpoint entry
  # mentions, so `Checkpoint.witnessed_head/3` — which reads entries by
  # `{resource_type, source_id}` — finds nothing for a promoted document until
  # the next scheduled checkpoint. That is a real window in which a truncation
  # of the newest anchors would not be caught, and it is silent. Minting here
  # closes it at promotion time instead of one interval later.
  #
  # **After the commit, not inside it.** `mint/1` publishes to the witness sink,
  # so calling it in the transaction would hold a DB transaction open across a
  # network call — and worse, it would commit to *uncommitted* heads: a rollback
  # would leave an immutable published object attesting a state that never
  # existed, which is the exact fingerprint `publish/2` treats as an attack.
  # A crash between commit and mint costs the window we already had.
  #
  # The old `("entry", source_id)` entries are deliberately left alone. Their
  # Merkle leaves commit to `resource_type` (`Checkpoint.leaf_content/2`), so
  # re-keying them would invalidate every stored proof against its published
  # root — and they are a true record of what that chain's head was under the
  # old type. Superseding history is not the same as rewriting it.
  #
  # A mint failure does not fail the promotion: the data move has already
  # committed, and the scheduled checkpoint will cover these heads on its next
  # run. It is logged rather than swallowed.
  defp recheckpoint(0, _org_id), do: :ok

  defp recheckpoint(_reattested, org_id) do
    if Checkpoint.enabled?() do
      mint_and_report(org_id)
    end

    :ok
  end

  # Rescued, like `CheckpointWorker.run_for_org/1` rescues the identical call.
  # `mint/1` raises on paths `{:error, _}` never reaches — a `Repo.query` match
  # in `current_heads/1`, a `create_chain_checkpoint_entry!` bang, and
  # `ExAws.request()` inside the S3 witness on bad adapter config. The promotion
  # has already committed by here, so letting one of those escape would report a
  # failure for work that succeeded, and `promote!/2` is documented as
  # all-or-nothing. Losing the checkpoint costs the window this change closes;
  # the scheduled run still covers these heads.
  defp mint_and_report(org_id) do
    case Checkpoint.mint(org_id) do
      {:ok, %{witnessed_at: nil} = checkpoint} ->
        # `mint/1` returns `{:ok, _}` when the row lands and *publication*
        # fails, by design — a sink that is briefly unreachable must not cost
        # the commitment. Saying "witnessed" here would contradict the
        # `witness_error` `publish/2` just logged, in the one place where
        # overstating coverage is the whole bug being fixed.
        Logger.warning(
          "Promotion minted checkpoint #{checkpoint.sequence} over the re-attested " <>
            "anchors, but it is NOT witnessed: #{inspect(checkpoint.witness_error)}. " <>
            "The commitment exists locally; the next checkpoint run retries publication."
        )

      {:ok, checkpoint} ->
        Logger.info(
          "Promotion minted checkpoint #{checkpoint.sequence} so the re-attested " <>
            "anchors are witnessed under their new type immediately (#849)."
        )

      {:error, reason} ->
        Logger.error(unwitnessed_message(inspect(reason)))
    end
  rescue
    error -> Logger.error(unwitnessed_message(Exception.message(error)))
  end

  # Deliberately does NOT point at `mix kiln.audit.checkpoint`: that task never
  # walks `chain_checkpoint_entries` (its reconciliation compares witness-sink
  # keys to checkpoint rows), so it would report green while the promoted
  # documents have no entry under their new type at all — advice that confirms
  # the opposite of what it claims to check.
  defp unwitnessed_message(reason) do
    "Promotion could not mint a checkpoint over the re-attested anchors: #{reason}. " <>
      "The promotion itself committed. The promoted documents stay unwitnessed under " <>
      "their new type until the next scheduled checkpoint — force one now with " <>
      "`KilnCMS.Governance.CheckpointWorker.run_for_org/1` if that window matters."
  end

  # Fired :entry artifacts and reference edges point at the old storage type —
  # drop them; the artifact API re-fires on demand under the compiled type.
  # The rows were already moved (same transaction), so stale means "no longer
  # present in the entries table" — which also sweeps leftovers from any
  # earlier promotion.
  defp purge_artifacts_and_edges do
    Repo.query!(
      """
      DELETE FROM published_artifacts
      WHERE document_type = 'entry'
        AND document_id NOT IN (SELECT id FROM entries)
      """,
      []
    )

    Repo.query!(
      """
      DELETE FROM reference_edges
      WHERE (from_type = 'entry' AND from_id NOT IN (SELECT id FROM entries))
         OR (to_type = 'entry' AND to_id NOT IN (SELECT id FROM entries))
      """,
      []
    )

    :ok
  end

  # Every custom field keeps working — it just belongs to the compiled type now.
  # `org_id` is left untouched, so the rescoped fields stay in the definition's
  # site; `type_definition_id` is a globally-unique key, so the WHERE already
  # matches only this definition's (same-org) fields — no org predicate needed.
  defp rescope_field_definitions(definition, target) do
    Repo.query!(
      """
      UPDATE field_definitions
      SET content_type = $1, type_definition_id = NULL
      WHERE type_definition_id = $2
      """,
      [to_string(target.type), Ecto.UUID.dump!(definition.id)]
    )

    :ok
  end

  # Archive (AshArchival soft-delete), returning the held notifications so the
  # caller can dispatch them post-commit.
  defp archive_definition(definition) do
    case Ash.destroy(definition, authorize?: false, return_notifications?: true) do
      {:ok, notifications} when is_list(notifications) -> notifications
      :ok -> []
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp table_for(resource), do: AshPostgres.DataLayer.Info.table(resource)

  # Quoted, comma-joined list of columns both tables have (minus the excluded
  # set) — resilient to shape differences between the entry tier and a target.
  defp shared_columns(source, target) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name FROM information_schema.columns
        WHERE table_name = $1 AND column_name IN (
          SELECT column_name FROM information_schema.columns WHERE table_name = $2
        )
        """,
        [source, target]
      )

    rows
    |> List.flatten()
    |> Kernel.--(@excluded_columns)
    |> Enum.map_join(", ", &~s("#{&1}"))
  end
end
