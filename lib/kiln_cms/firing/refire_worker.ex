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
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 60,
      keys: [:type, :id],
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  alias KilnCMS.Firing.{Engine, References}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => type_str, "id" => id, "visited" => visited}}) do
    type = References.type_atom(type_str)
    node_key = type && References.key(type, id)

    cond do
      is_nil(type) -> :ok
      node_key in visited -> :ok
      true -> refire(type, id, visited ++ [node_key])
    end
  end

  defp refire(type, id, visited) do
    case References.load_published(type, id) do
      {:ok, document} ->
        Engine.fire(document)
        References.invalidate(type, id, visited)

      :error ->
        :ok
    end
  end
end
