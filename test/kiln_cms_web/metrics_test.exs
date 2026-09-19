defmodule KilnCMSWeb.MetricsTest do
  @moduledoc """
  The opt-in Prometheus exporter (#1362): off by default, and when on, a
  `/metrics` listener that actually carries `KilnCMSWeb.Telemetry.metrics/0`.

  `async: false` because the reporter registers a fixed name and attaches
  VM-global telemetry handlers.
  """
  use KilnCMSWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMSWeb.Metrics

  doctest KilnCMSWeb.Telemetry

  @enabled [enabled: true, port: 0, bind: :loopback, token: nil]

  describe "children/1" do
    test "is empty under the shipped config: no reporter, no port" do
      assert Application.get_env(:kiln_cms, Metrics)[:enabled] == false
      assert Metrics.children() == []
    end

    test "binding every interface without a token warns" do
      log = capture_log(fn -> Metrics.children(Keyword.put(@enabled, :bind, :all)) end)
      assert log =~ "KILN_METRICS_BIND=all with no KILN_METRICS_TOKEN"
    end

    test "loopback, or a token, is quiet" do
      assert capture_log(fn -> Metrics.children(@enabled) end) == ""

      assert capture_log(fn ->
               Metrics.children(Keyword.merge(@enabled, bind: :all, token: "s3cret"))
             end) == ""
    end
  end

  describe "the listener" do
    test "serves /metrics on loopback only, and nothing else" do
      port = start_exporter(@enabled)
      :telemetry.execute([:kiln_cms, :cache, :content], %{count: 1}, %{result: :hit})

      assert %{status: 200, body: body} = Req.get!("http://127.0.0.1:#{port}/metrics")
      assert body =~ ~s|kiln_cms_cache_content_count{result="hit"} 1|

      assert %{status: 404} = Req.get!("http://127.0.0.1:#{port}/")
      assert %{status: 404} = Req.post!("http://127.0.0.1:#{port}/metrics", body: "")
    end

    test "requires the bearer token when one is configured" do
      port = start_exporter(Keyword.put(@enabled, :token, "s3cret"))
      url = "http://127.0.0.1:#{port}/metrics"

      assert %{status: 401} = Req.get!(url)
      assert %{status: 401} = Req.get!(url, auth: {:bearer, "wrong"})
      assert %{status: 401} = Req.get!(url, headers: [authorization: "s3cret"])
      assert %{status: 200} = Req.get!(url, auth: {:bearer, "s3cret"})
    end
  end

  describe "what a scrape carries" do
    setup do
      start_exporter(@enabled)
      :ok
    end

    test "request latency as a histogram, labelled by route pattern", %{conn: conn} do
      conn |> get(~p"/api/locales") |> json_response(200)

      body = scrape()
      assert body =~ "# TYPE phoenix_router_dispatch_stop_duration histogram"
      assert body =~ ~s|phoenix_router_dispatch_stop_duration_bucket{route="/api/locales",le="|
      assert body =~ ~s|phoenix_router_dispatch_stop_duration_count{route="/api/locales"} 1|
    end

    test "a compiled content type keeps its name; an admin-defined one is folded" do
      for type <- ["page", "acme_recipe"] do
        :telemetry.execute(
          [:kiln_cms, :delivery, :render],
          %{duration: System.convert_time_unit(3, :millisecond, :native), count: 1},
          %{type: type, status: 200}
        )
      end

      body = scrape()
      assert body =~ ~s|kiln_cms_delivery_render_duration_count{status="200",type="page"} 1|
      assert body =~ ~s|kiln_cms_delivery_render_duration_count{status="200",type="dynamic"} 1|
      refute body =~ "acme_recipe"
    end
  end

  describe "KilnCMSWeb.Telemetry.metrics/0" do
    test "has no summaries — the exporter would drop them" do
      summaries =
        for %Telemetry.Metrics.Summary{name: name} <- KilnCMSWeb.Telemetry.metrics(), do: name

      assert summaries == []
    end

    test "tags nothing unbounded" do
      unbounded = [:org_id, :content_id, :user_id, :actor_id, :id, :slug, :path, :request_path]

      offenders =
        for metric <- KilnCMSWeb.Telemetry.metrics(),
            tag <- metric.tags,
            tag in unbounded,
            do: {metric.name, tag}

      assert offenders == []
    end
  end

  # Starts the reporter and its listener as `children/1` returns them, on an
  # ephemeral port, and returns that port.
  defp start_exporter(config) do
    [peep, bandit] = Metrics.children(config)
    start_supervised!(peep)
    listener = start_supervised!(bandit)
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
    port
  end

  defp scrape do
    conn = Metrics.call(Plug.Test.conn(:get, "/metrics"), Metrics.init([]))
    assert conn.status == 200
    conn.resp_body
  end
end
