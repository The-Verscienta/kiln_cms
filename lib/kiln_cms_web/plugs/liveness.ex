defmodule KilnCMSWeb.Plugs.Liveness do
  @moduledoc """
  Answers `GET /live` with a bare `200 OK`, short-circuiting the pipeline (#816).

  This is the **liveness** probe — what a restart-triggering healthcheck (the
  Docker `HEALTHCHECK`) points at. It must not depend on the database: restarting
  the app on a database outage it can't fix only restart-storms the replicas
  exactly when the platform is already degraded.

  It runs as an **endpoint plug ahead of `Plugs.SetTenant`** rather than a router
  action, and that placement is the whole point. `SetTenant` resolves the org
  from the request `Host` for every request, and for a healthcheck's
  `127.0.0.1` host that resolution reaches the database (`Tenant.fetch_org` →
  `by_custom_domain`/`default_org`). So a `/live` served through the router would
  fail on a database outage — the exact failure this probe exists to avoid.
  Answering here, before session/parsing/tenant resolution, keeps liveness a
  pure "is this process serving HTTP" signal. `/up` and `/ready`
  (`KilnCMSWeb.HealthController`) stay DB-coupled on purpose — that is the
  readiness signal a load balancer wants when deciding whether to route here.

  Two separate preconditions make the healthcheck's `http://127.0.0.1/live`
  work, and they run in this order: `Plug.SSL` (Phoenix injects it at the front
  of the endpoint, ahead of this plug) must NOT 301 it to https — which holds
  because `config/prod.exs`'s `force_ssl` excludes host `127.0.0.1`; and THEN
  this plug answers before `SetTenant`'s DB read. The placement here buys the
  DB-freedom; the force_ssl exclude buys the no-redirect.

  **One boot-time exception** (#2166): until `KilnCMS.Search.Warmup` has run
  its first search, this answers `503 warming up`. That is the signal the
  platform swaps traffic on (the image's `HEALTHCHECK`, and through it
  Coolify), and a node that said 200 while its embedding serving was still
  compiling took production searches for 27 s. The latch is in memory, so the
  probe stays DB-free, and it only ever opens: once a node is warm nothing
  here can fail again, so a database outage still cannot restart-storm it.
  The warm-up is capped (`KilnCMS.Search.Warmup.timeout/0`) inside the
  healthcheck's start period and retries.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", request_path: "/live"} = conn, _opts) do
    {status, body} = if KilnCMS.Search.Warmup.ready?(), do: {200, "OK"}, else: {503, "warming up"}

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
    |> halt()
  end

  def call(conn, _opts), do: conn
end
