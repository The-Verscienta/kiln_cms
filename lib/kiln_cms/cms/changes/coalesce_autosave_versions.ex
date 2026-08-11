defmodule KilnCMS.CMS.Changes.CoalesceAutosaveVersions do
  @moduledoc """
  Collapses the run of draft-autosave PaperTrail versions into a single snapshot
  so debounced autosaves don't flood version history (issue #32).

  Draft autosave (`:autosave`) is versioned like any other update, but each
  debounced save would otherwise add a row. After the autosave version is
  committed, this change merges every *trailing* `:autosave` version — those
  recorded since the most recent non-autosave (manual / workflow) version — into
  the newest one, then deletes the now-redundant older autosave rows. Merging
  preserves the cumulative `:changes_only` delta of the whole run, so version
  replay (`RestoreVersion`) stays correct even though intermediate rows are gone.

  Manual saves and workflow transitions write their own distinctly-named
  versions and are never touched, so history stays meaningful while a draft keeps
  exactly one "latest autosaved draft" restore point between manual saves.

  ## Anchored rows are never touched (#671)

  A row an anchor has committed to is immutable, and not by convention: deleting
  or rewriting one means that anchor can never reproduce, no later anchor
  repairs it, and `KilnCMS.Governance.Chain.verify/4` reports `{:tampered, …}`
  forever — a verdict indistinguishable from real tampering, on a document
  nobody touched.

  With `audit_anchor_every_write` on, that is exactly what this change used to
  do. Each autosave is anchored, so the next autosave deleted rows the previous
  anchor covered and rewrote the `changes` of another. Two features that are each
  correct alone, fatal together, on the one configuration that exists to make the
  audit surface *stronger* — and autosave is on by default in the editor, so it
  needed no unusual usage, just the one flag.

  So the run is cut at `Chain.anchored_boundary/1` as well as at the last manual
  version. The cost is real, and falls only where the flag is on: when every save
  is anchored, every autosave row is anchored the moment it is written, so there
  is never an unanchored pair to collapse and history grows one row per debounce
  — which is what #32 added coalescing to avoid. That is the honest trade between
  the two features rather than a way to have both, and
  `docs/editorial-consent.md` states it as the cost of the setting. With the flag
  off (the default) anchoring happens at publish, a publish is itself a
  non-autosave version, so the two boundaries coincide and behaviour is
  unchanged.

  Runs in `after_transaction` (so the just-written version row exists before we
  coalesce) and as a system caller (`authorize?: false`) since version
  update/destroy is otherwise forbidden by `KilnCMS.CMS.VersionPolicies`.
  """
  use Ash.Resource.Change

  alias KilnCMS.Governance.Chain

  require Ash.Query
  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, record} ->
          coalesce(record)
          result

        _ ->
          result
      end
    end)
  end

  defp coalesce(record) do
    version_module = Module.concat(record.__struct__, Version)

    case coalescible_versions(version_module, record) do
      # Nothing to collapse: a single (or zero) unanchored trailing autosave.
      versions when length(versions) <= 1 ->
        :ok

      versions ->
        {keep, superseded} = List.pop_at(versions, -1)

        # The shared fold (#692), not a third copy of `Map.merge`: the row this
        # writes has to replay identically to the rows it is about to delete, and
        # `VersionSnapshot` is what will do the replaying.
        merged = KilnCMS.CMS.VersionSnapshot.merge(versions)

        Ash.update!(keep, %{changes: merged},
          action: :update,
          authorize?: false,
          tenant: record.org_id
        )

        Enum.each(
          superseded,
          &Ash.destroy!(&1, action: :destroy, authorize?: false, tenant: record.org_id)
        )
    end
  rescue
    # `after_transaction` runs after the editor's save has already committed, so
    # a raise here reaches `AshPhoenix.Form.submit`'s caller as an exception
    # rather than an error tuple — the LiveView crashes, remounts, and drops the
    # socket-held block state `do_autosave/1` exists to preserve, over a save
    # that actually succeeded. `Chain.anchor/2` and `extend/2` are wrapped for
    # the same reason: tidying history must not cost an editor their save. The
    # cost of skipping is version rows, which is the same cost the anchored cut
    # above already accepts.
    error ->
      Logger.error("Autosave version coalescing failed (save unaffected): #{inspect(error)}")
      :ok
  end

  # The contiguous run of autosave versions newer than the most recent manual
  # (non-autosave) version AND outside every anchor's fold, ordered
  # oldest → newest.
  #
  # Sorted on `(version_inserted_at, id)` — the key the chain folds on — so
  # "the newest" means the same row here and there when two saves land in the
  # same microsecond.
  defp coalescible_versions(version_module, record) do
    case Chain.anchored_boundary(record) do
      # The boundary could not be read, so which rows are anchored is unknown.
      # Coalescing the wrong ones is unrecoverable and skipping is not, so this
      # keeps the extra version rows and moves on.
      :unknown ->
        []

      boundary ->
        version_module
        |> Ash.Query.filter(version_source_id == ^record.id and version_action_name == :autosave)
        |> Ash.Query.sort(version_inserted_at: :asc, id: :asc)
        |> after_latest_manual(version_module, record)
        |> Chain.after_anchored(boundary)
        |> Ash.read!(authorize?: false, tenant: record.org_id)
    end
  end

  defp after_latest_manual(query, version_module, record) do
    case latest_manual_version_timestamp(version_module, record.id, record.org_id) do
      nil -> query
      boundary -> Ash.Query.filter(query, version_inserted_at > ^boundary)
    end
  end

  defp latest_manual_version_timestamp(version_module, source_id, org_id) do
    version_module
    |> Ash.Query.filter(version_source_id == ^source_id and version_action_name != :autosave)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false, tenant: org_id)
    |> case do
      nil -> nil
      version -> version.version_inserted_at
    end
  end
end
