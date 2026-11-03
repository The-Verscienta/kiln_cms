defmodule KilnCMSWeb.HealthWarmupTest do
  @moduledoc """
  The probes hold traffic off a node until search has warmed up (#2166) —
  `/live` included, since it is what the image's healthcheck, and Coolify
  through it, swap on. The latch itself is `KilnCMS.Search.WarmupTest`.
  """
  # async: false — flips the node-global warm-up latch.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Search.Warmup

  setup do
    Warmup.put_ready(false)
    on_exit(fn -> Warmup.put_ready(true) end)
  end

  test "/live answers 503 until warm, without touching the database", %{conn: conn} do
    conn = get(conn, "/live")
    assert response(conn, 503) == "warming up"
    # Still answered ahead of SetTenant (#816).
    refute Map.has_key?(conn.assigns, :current_org)

    Warmup.put_ready(true)
    assert build_conn() |> get("/live") |> response(200) == "OK"
  end

  test "/up and /ready answer 503 until warm", %{conn: conn} do
    assert conn |> get(~p"/up") |> response(503) == "warming up"

    body = build_conn() |> get(~p"/ready") |> json_response(503)
    assert body["status"] == "degraded"
    assert body["db"] == "ok"
    assert body["search"] == "warming"

    Warmup.put_ready(true)
    assert build_conn() |> get(~p"/ready") |> json_response(200) |> Map.fetch!("search") == "ok"
  end
end
