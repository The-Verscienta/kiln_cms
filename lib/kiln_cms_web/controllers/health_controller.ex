defmodule KilnCMSWeb.HealthController do
  @moduledoc """
  Liveness/readiness probe at `GET /up` for load balancers, uptime monitors,
  and Coolify. Returns 200 only when the database is reachable, else 503.
  """
  use KilnCMSWeb, :controller

  def show(conn, _params) do
    case check_db() do
      :ok -> send_resp(conn, 200, "OK")
      :error -> send_resp(conn, 503, "database unavailable")
    end
  end

  defp check_db do
    case Ecto.Adapters.SQL.query(KilnCMS.Repo, "SELECT 1", []) do
      {:ok, _} -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
