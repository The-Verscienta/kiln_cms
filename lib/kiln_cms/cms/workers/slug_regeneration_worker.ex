defmodule KilnCMS.CMS.Workers.SlugRegenerationWorker do
  @moduledoc """
  Runs a bulk slug regeneration (#455) off the request path — the admin UI
  enqueues here so large sites don't tie up a LiveView. Progress and the final
  summary broadcast on `"slug_regen:<org_id>"` for `/editor/slugs` to render.

  `max_attempts: 1`: the run is idempotent (already-renamed records no-op on a
  re-run), but a bulk admin action shouldn't silently restart itself — a
  failed job is visible in Oban and the admin re-triggers deliberately.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias KilnCMS.CMS.SlugRegeneration

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{"org_id" => org_id, "kind" => kind} = args

    summary =
      SlugRegeneration.run(parse_kind(kind), org_id,
        include_pinned: args["include_pinned"] == true,
        actor: load_actor(args["actor_id"]),
        on_progress: fn progress -> broadcast(org_id, {:slug_regen_progress, progress}) end
      )

    broadcast(org_id, {:slug_regen_done, summary})
    :ok
  end

  @doc "Enqueue a run for the admin UI."
  def enqueue(org_id, kind, include_pinned?, actor) do
    %{
      org_id: org_id,
      kind: to_string(kind),
      include_pinned: include_pinned?,
      actor_id: actor && actor.id
    }
    |> new()
    |> Oban.insert()
  end

  @doc false
  def topic(org_id), do: "slug_regen:#{org_id}"

  defp broadcast(org_id, message),
    do: Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic(org_id), message)

  defp parse_kind("all"), do: :all
  defp parse_kind(kind), do: kind

  defp load_actor(nil), do: nil

  defp load_actor(actor_id) do
    case KilnCMS.Accounts.get_user(actor_id, authorize?: false) do
      {:ok, user} -> user
      _ -> nil
    end
  end
end
