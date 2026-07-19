defmodule KilnCMS.Firing.RefireWorker do
  @moduledoc """
  Re-fires one referrer document and propagates the wave (Kiln v2 — decision D13).

  Cycle-safe: each node is fired at most once per wave via the accumulating
  `visited` set. Only published documents re-fire; everything else is a no-op.
  """
  # Bound refire storms for hub documents: dedupe pending refire jobs by node
  # (type+id), ignoring the per-path `visited` set so a fan-in doesn't enqueue
  # the same node many times over.
  use Oban.Worker,
    queue: :firing,
    max_attempts: 3,
    unique: [
      period: 60,
      # `:org_id` in the dedup key so a fan-in in one org can't collapse another
      # org's refire of the same `{type, id}` (epic #336).
      keys: [:org_id, :type, :id],
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  alias KilnCMS.Firing.{Engine, References}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"org_id" => org_id, "type" => type_str, "id" => id, "visited" => visited}
      }) do
    type = References.type_atom(type_str)
    node_key = type && References.key(type, id)

    cond do
      is_nil(type) -> :ok
      node_key in visited -> :ok
      true -> refire(org_id, type, id, visited ++ [node_key])
    end
  end

  # Back-compat (epic #336): a re-fire job enqueued by the pre-multi-tenancy
  # release has no `"org_id"`. Default it to the sole org and re-dispatch instead
  # of crashing across the deploy boundary. Re-fire waves fan out widely, so many
  # such jobs can be in flight at cutover.
  def perform(%Oban.Job{args: %{"type" => _, "id" => _, "visited" => _} = args} = job) do
    perform(%{job | args: Map.put(args, "org_id", KilnCMS.Accounts.default_org_id())})
  end

  defp refire(org_id, type, id, visited) do
    case References.load_published(org_id, type, id) do
      {:ok, document} ->
        Engine.fire(document)
        References.invalidate(org_id, type, id, visited)

      :error ->
        :ok
    end
  end
end
