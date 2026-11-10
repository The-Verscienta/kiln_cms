defmodule KilnCMS.CMS.Changes.FireArtifacts do
  @moduledoc """
  Enqueues artifact firing after a publish transition (Kiln v2 — decision D9).

  Runs in `after_transaction` so it sees the committed record, then enqueues a
  `KilnCMS.Firing.FireWorker` (queue `:firing`) and returns — the publish action
  no longer blocks on the per-surface render + artifact upserts + reference
  rebuild (perf #201). Delivery and the artifact API fall back to a live render
  on a miss, so content is served in the brief window before the artifact lands.
  Enqueue failures are logged but never fail the action.

  Pass `only_when: :published` to enqueue only when the resulting record is in
  the `:published` state. The generic `:update` action uses this (#330): a
  headless write-through / in-place edit of already-live content re-fires its
  artifact, while draft edits (state != :published) stay silent — firing on a
  draft would be wasted work and could publish an artifact for unpublished
  content.

  Pass `skip_trashed: true` to enqueue only when the record the write
  RETURNED is out of the trash (`archived_at` nil). For an action allowed to
  write a trashed row (`Changes.RefuseTrashed`'s exemptions): its artifacts
  were purged when it was trashed, and a fire would put them back. It judges
  the row the `UPDATE` returned, not the struct the caller read, because a
  trash or a restore in between bumps nothing a compare-and-swap could see:
  a row restored after the read must still fire, or the restore's own fire
  may have delivered the shape from before this write (#2533). To get that
  value back, the option adds a no-op `archived_at = archived_at` to the
  write: the data layer returns only the attributes a write sets.

  The job carries the date the write pinned for computed fields' `today()`
  (`KilnCMS.CMS.Computed.Context.pin_today/1`), when it pinned one, so the
  fire derives the same values the write just stored — even when the queue
  only reaches it after the site's midnight.
  """
  use Ash.Resource.Change

  require Ash.Expr
  require Logger

  @impl true
  def change(changeset, opts, _context) do
    only_when = Keyword.get(opts, :only_when)
    skip_trashed? = Keyword.get(opts, :skip_trashed, false)

    changeset
    |> then(&if(skip_trashed?, do: return_archived_at(&1), else: &1))
    |> Ash.Changeset.after_transaction(&enqueue_firing(&1, &2, only_when, skip_trashed?))
  end

  # The data layer hands back the struct the caller read, with only the
  # attributes this write sets taken from the row it returned. Setting the
  # archive attribute to itself writes nothing new, but puts the row's own
  # value, as the `UPDATE` saw it, on the record the hook gets.
  defp return_archived_at(changeset) do
    attribute = AshArchival.Resource.Info.archive_attribute!(changeset.resource)
    Ash.Changeset.atomic_update(changeset, attribute, Ash.Expr.expr(^Ash.Expr.ref(attribute)))
  end

  # Only enqueue on a committed success; pass any error result straight through.
  defp enqueue_firing(changeset, {:ok, record} = result, only_when, skip_trashed?) do
    if fire?(only_when, record) and not (skip_trashed? and trashed?(changeset, record)),
      do: enqueue(record, KilnCMS.CMS.Computed.Context.pinned(changeset))

    result
  end

  defp enqueue_firing(_changeset, result, _only_when, _skip_trashed?), do: result

  defp trashed?(changeset, record) do
    attribute = AshArchival.Resource.Info.archive_attribute!(changeset.resource)
    Map.get(record, attribute) != nil
  end

  defp fire?(nil, _record), do: true
  defp fire?(:published, %{state: :published}), do: true
  defp fire?(:published, _record), do: false

  defp enqueue(record, today) do
    type = KilnCMS.Firing.Engine.document_type(record)

    # Carry the record's tenant (epic #336) so the worker fires into the right org.
    case %{"org_id" => record.org_id, "type" => to_string(type), "id" => record.id}
         |> put_today(today)
         |> KilnCMS.Firing.FireWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Enqueue firing failed for #{record.id}: #{inspect(reason)}")
    end
  end

  defp put_today(args, nil), do: args
  defp put_today(args, %Date{} = today), do: Map.put(args, "today", Date.to_iso8601(today))
end
