defmodule KilnCMSWeb.EndpointTest do
  @moduledoc """
  #702: `Phoenix.LiveDashboard.RequestLogger` is gated on `dev_routes`, the
  same flag that mounts `/dashboard` — a request must not pay the
  `fetch_cookies`/token-verify cost for a dashboard that doesn't exist in
  this build (`dev_routes` is unset/false under `:test`, same as `:prod`).

  The plug sets no cookie and no response header — its only observable
  effect is `Logger.metadata/1` when a *valid* signed token verifies
  (`request_logger.ex`'s `verify_value/3`). `Phoenix.ConnTest` runs the
  endpoint pipeline in the test's own process, so that metadata is visible
  here directly: present would mean the plug ran, however it's gated.
  """
  use KilnCMSWeb.ConnCase, async: false

  setup do
    Logger.reset_metadata([])
    on_exit(fn -> Logger.reset_metadata([]) end)
  end

  test "a request carrying a validly signed request_logger token sets no logger metadata", %{
    conn: conn
  } do
    token = Phoenix.LiveDashboard.RequestLogger.sign(KilnCMSWeb.Endpoint, "request_logger", "s")

    conn = get(conn, "/up?request_logger=#{token}")

    assert conn.status == 200
    refute Keyword.has_key?(Logger.metadata(), :logger_pubsub_backend)
  end
end
