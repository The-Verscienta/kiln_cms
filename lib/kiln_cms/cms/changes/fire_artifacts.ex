defmodule KilnCMS.CMS.Changes.FireArtifacts do
  @moduledoc """
  Enqueues artifact firing after a publish transition (Kiln v2 — decision D9).

  Runs in `after_transaction` so it sees the committed record, then enqueues a
  `KilnCMS.Firing.FireWorker` (queue `:firing`) and returns — the publish action
  no longer blocks on the 3-surface render + artifact upserts + reference
  rebuild (perf #201). Delivery and the artifact API fall back to a live render
  on a miss, so content is served in the brief window before the artifact lands.
  Enqueue failures are logged but never fail the action.

  Pass `only_when: :published` to enqueue only when the resulting record is in
  the `:published` state. The generic `:update` action uses this (#330): a
  headless write-through / in-place edit of already-live content re-fires its
  artifact, while draft edits (state != :published) stay silent — firing on a
  draft would be wasted work and could publish an artifact for unpublished
  content.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, opts, _context) do
    only_when = Keyword.get(opts, :only_when)
    Ash.Changeset.after_transaction(changeset, &enqueue_firing(&1, &2, only_when))
  end

  # Only enqueue on a committed success; pass any error result straight through.
  defp enqueue_firing(_changeset, {:ok, record} = result, only_when) do
    if fire?(only_when, record), do: enqueue(record)
    result
  end

  defp enqueue_firing(_changeset, result, _only_when), do: result

  defp fire?(nil, _record), do: true
  defp fire?(:published, %{state: :published}), do: true
  defp fire?(:published, _record), do: false

  defp enqueue(record) do
    type = KilnCMS.Firing.Engine.document_type(record)

    case %{"type" => to_string(type), "id" => record.id}
         |> KilnCMS.Firing.FireWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Enqueue firing failed for #{record.id}: #{inspect(reason)}")
    end
  end
end
