defmodule KilnCMSWeb.Metrics do
  @moduledoc """
  The opt-in Prometheus exporter for `KilnCMSWeb.Telemetry.metrics/0` (#1362).

  Off by default. With `KILN_METRICS_ENABLED` on, `children/1` starts two
  processes under `KilnCMSWeb.Telemetry`:

    * a [Peep](https://hexdocs.pm/peep) reporter, which attaches a handler for
      every metric and aggregates as events arrive — counters and gauges as
      numbers, distributions into log-spaced histogram buckets — so its memory
      is bounded by the number of series, not by traffic or by how long it has
      gone unscraped;
    * a Bandit listener serving this module as a plug, which answers
      `GET /metrics` in the Prometheus text format and nothing else.

  With it off, `children/1` returns `[]`: no handler is attached, no port is
  opened, and the metric definitions record nothing.

  ## Exposure

  A scrape reveals traffic shape, editorial volume and the route table, so the
  listener is deliberately **not** a route on the public endpoint. It has its
  own port (`KILN_METRICS_PORT`, default `9568`), and binds to loopback unless
  `KILN_METRICS_BIND=all`. A separate listener also means a scrape never passes
  through host-based tenant resolution, sessions or rate limiting, and never
  shows up in the `phoenix.*` latency it is measuring.

  `KILN_METRICS_TOKEN`, when set, is required as `Authorization: Bearer
  <token>` and compared in constant time. Binding to every interface without
  one logs a warning at boot rather than refusing to start: some platform
  scrapers (Fly's) cannot send a header, and on a private network the port is
  the control.

  See `docs/observability.md` for scrape configuration and
  `docs/environment-variables.md` for the variables.
  """
  @behaviour Plug

  import Plug.Conn

  require Logger

  @reporter :kiln_cms_metrics

  @loopback {127, 0, 0, 1}
  # The same "every interface" shape the public endpoint binds in production
  # (config/runtime/prod/web.exs): IPv6-any, which also accepts IPv4 on a
  # dual-stack host — and Fly's private network, for one, is IPv6-only.
  @any {0, 0, 0, 0, 0, 0, 0, 0}

  @doc """
  The child specs to start under `KilnCMSWeb.Telemetry`: the reporter and its
  listener when enabled, otherwise none.

  `config` defaults to `Application.get_env(:kiln_cms, KilnCMSWeb.Metrics)`
  (keys `:enabled`, `:port`, `:bind`, `:token`; see `config/config.exs`).
  """
  @spec children(keyword()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(config \\ Application.get_env(:kiln_cms, __MODULE__, [])) do
    if Keyword.get(config, :enabled, false) do
      bind = Keyword.get(config, :bind, :loopback)
      token = Keyword.get(config, :token)
      warn_if_unauthenticated(bind, token)

      [
        {Peep, name: @reporter, metrics: KilnCMSWeb.Telemetry.metrics()},
        {Bandit,
         plug: {__MODULE__, token: token},
         scheme: :http,
         ip: ip(bind),
         port: Keyword.get(config, :port, 9568)}
      ]
    else
      []
    end
  end

  @doc """
  The name the Peep reporter is registered under.
  """
  @spec reporter() :: atom()
  def reporter, do: @reporter

  @impl Plug
  def init(opts), do: %{token: Keyword.get(opts, :token)}

  @impl Plug
  def call(%Plug.Conn{method: "GET", path_info: ["metrics"]} = conn, %{token: token}) do
    if authorized?(conn, token) do
      body = @reporter |> Peep.get_all_metrics() |> Peep.Prometheus.export()

      conn
      |> put_resp_content_type("text/plain; version=0.0.4")
      |> send_resp(200, body)
    else
      conn
      |> put_resp_header("www-authenticate", "Bearer")
      |> send_resp(401, "")
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "")

  defp authorized?(_conn, nil), do: true

  defp authorized?(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> given] -> Plug.Crypto.secure_compare(given, token)
      _ -> false
    end
  end

  defp ip(:all), do: @any
  defp ip(:loopback), do: @loopback

  defp warn_if_unauthenticated(:all, nil) do
    Logger.warning(
      "KILN_METRICS_BIND=all with no KILN_METRICS_TOKEN: /metrics is served " <>
        "unauthenticated on every interface. Keep the port off the public " <>
        "network, or set a token."
    )
  end

  defp warn_if_unauthenticated(_bind, _token), do: :ok
end
