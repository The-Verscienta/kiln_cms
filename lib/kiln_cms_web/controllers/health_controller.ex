defmodule KilnCMSWeb.HealthController do
  @moduledoc """
  Health probes for load balancers, uptime monitors, and Coolify.

    `GET /live` — **liveness** — is not here: it is answered by the endpoint plug
    `KilnCMSWeb.Plugs.Liveness`, ahead of `SetTenant`, so the DB-free liveness
    signal a restart-triggering healthcheck needs never reaches host resolution
    (a DB read). See that plug and #816.

    * `GET /up` — **readiness**: a cheap text probe that returns 200 only when
      the database is also reachable, else 503. For a load balancer / uptime
      monitor deciding whether to route traffic here — not for triggering a
      restart. (Kept as `/up` for the platforms and monitors already dialing it.)
    * `GET /ready` — **readiness+**: a JSON probe reporting database connectivity
      and Oban background-queue depth, for monitoring/alerting sinks. Returns
      200 when the database is reachable, else 503, with the queue-depth payload
      either way.

  See `docs/observability.md` for the alert rules that consume `/ready`.
  """
  use KilnCMSWeb, :controller

  import Ecto.Query, only: [from: 2]

  def show(conn, _params) do
    case check_db() do
      :ok -> send_resp(conn, 200, "OK")
      :error -> send_resp(conn, 503, "database unavailable")
    end
  end

  def ready(conn, _params) do
    db = check_db()

    payload = %{
      status: if(db == :ok, do: "ok", else: "degraded"),
      db: to_string(db),
      oban: oban_depth()
    }

    conn
    |> put_status(if(db == :ok, do: :ok, else: :service_unavailable))
    |> json(payload)
  end

  defp check_db do
    case Ecto.Adapters.SQL.query(KilnCMS.Repo, "SELECT 1", []) do
      {:ok, _} -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # Background-queue backlog: jobs waiting to run (`available`) or awaiting a
  # retry (`retryable`). A persistently climbing depth means workers can't keep
  # up — the signal the alert rules in docs/observability.md watch.
  defp oban_depth do
    query =
      from(j in "oban_jobs",
        where: j.state in ["available", "retryable"],
        group_by: j.state,
        select: {j.state, count(j.id)}
      )

    counts = KilnCMS.Repo.all(query) |> Map.new()

    available = Map.get(counts, "available", 0)
    retryable = Map.get(counts, "retryable", 0)

    %{available: available, retryable: retryable, backlog: available + retryable}
  rescue
    _ -> %{available: nil, retryable: nil, backlog: nil}
  end
end
