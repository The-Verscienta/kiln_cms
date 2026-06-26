defmodule KilnCMS.CMS.Changes.FireArtifacts do
  @moduledoc """
  Enqueues artifact firing after a publish transition (Kiln v2 — decision D9).

  Runs in `after_transaction` so it sees the committed record, then enqueues a
  `KilnCMS.Firing.FireWorker` (queue `:firing`) and returns — the publish action
  no longer blocks on the 3-surface render + artifact upserts + reference
  rebuild (perf #201). Delivery and the artifact API fall back to a live render
  on a miss, so content is served in the brief window before the artifact lands.
  Enqueue failures are logged but never fail the publish.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, &enqueue_firing/2)
  end

  # Only enqueue on a committed publish; pass any error result straight through.
  defp enqueue_firing(_changeset, {:ok, record} = result) do
    type = KilnCMS.Firing.Engine.document_type(record)

    case %{"type" => to_string(type), "id" => record.id}
         |> KilnCMS.Firing.FireWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Enqueue firing failed for #{record.id}: #{inspect(reason)}")
    end

    result
  end

  defp enqueue_firing(_changeset, result), do: result
end
