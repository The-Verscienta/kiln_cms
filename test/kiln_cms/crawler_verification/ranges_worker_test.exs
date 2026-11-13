defmodule KilnCMS.CrawlerVerification.RangesWorkerTest do
  @moduledoc """
  Fetching the published crawler range lists (#2586) through
  `KilnCMS.SafeFetch`, against a `Req.Test` stub: nothing reaches the network.
  """
  # Not async: the lists are VM-global, telemetry handlers see every process's
  # events, and some tests change the `Ranges` and `CrawlerVerification`
  # config with `Application.put_env/3`.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog

  alias KilnCMS.Application, as: App
  alias KilnCMS.CrawlerVerification
  alias KilnCMS.CrawlerVerification.Engines
  alias KilnCMS.CrawlerVerification.Ranges
  alias KilnCMS.CrawlerVerification.RangesWorker

  @moduletag :capture_log

  @stub KilnCMS.CrawlerVerification.Ranges
  @fetch [:kiln_cms, :crawler_verification, :ranges_fetch]

  @v4 "45.143.200.0/24"
  @inside_v4 {45, 143, 200, 7}

  setup do
    Ranges.clear()
    on_exit(&Ranges.clear/0)
    restore_env(Ranges)
    restore_env(CrawlerVerification)

    test = self()
    id = "ranges-worker-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(id, @fetch, fn _, m, meta, _ -> send(test, {:fetch, m, meta}) end, nil)
    on_exit(fn -> :telemetry.detach(id) end)

    Phoenix.PubSub.subscribe(KilnCMS.PubSub, Ranges.topic())
    :ok
  end

  test "a fetch installs every vendor's list and sends it to the other nodes" do
    stub_all(fn _engine -> {200, list([@v4])} end)

    assert perform_job(RangesWorker, %{}) == :ok

    for engine <- Engines.range_engines() do
      assert Ranges.lookup(engine, @inside_v4) == :in
      assert_received {:crawler_ranges, 1, ^engine, [@v4], age} when age >= 0
      assert_received {:fetch, %{count: 1}, %{engine: ^engine, result: :ok}}
    end
  end

  test "asks each vendor's own URL, over HTTPS, as a bare KilnCMS client" do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      send(test, {:request, conn.scheme, conn.host, conn.request_path, conn.req_headers})
      Req.Test.json(conn, %{"prefixes" => [%{"ipv4Prefix" => @v4}]})
    end)

    assert perform_job(RangesWorker, %{}) == :ok

    for engine <- Engines.range_engines() do
      uri = URI.parse(Engines.range_source(engine))
      host = uri.host
      path = uri.path
      assert_received {:request, :https, ^host, ^path, headers}
      assert {"user-agent", "KilnCMS"} in headers
    end
  end

  test "a failed fetch keeps the old list and its age, which then goes stale" do
    now = System.monotonic_time(:millisecond)
    Ranges.put_fixture(:duckduckgo, [@v4], age_ms: :timer.hours(3), now: now)

    stub_all(fn
      :duckduckgo -> 500
      _engine -> {200, list(["45.143.202.0/24"])}
    end)

    log = capture_log(fn -> assert {:error, _} = perform_job(RangesWorker, %{}) end)

    assert log =~ "duckduckgo"
    refute log =~ "45.143."
    assert_received {:fetch, _, %{engine: :duckduckgo, result: :http_error}}
    refute_received {:crawler_ranges, 1, :duckduckgo, _, _}

    assert Ranges.lookup(:duckduckgo, @inside_v4) == :in
    assert Ranges.status().duckduckgo.age_ms >= :timer.hours(3)

    stale = now + Ranges.config()[:max_age_ms] - :timer.hours(3) + 1_000
    assert Ranges.lookup(:duckduckgo, @inside_v4, now: stale) == :unknown

    assert CrawlerVerification.check(:duckduckgo, @inside_v4, ranges: [now: stale]) ==
             {:unverified, :unverifiable}
  end

  test "a transport error keeps the old list" do
    Ranges.put_fixture(:bing, [@v4])
    stub_all(fn _engine -> :transport_error end)

    assert {:error, {:crawler_ranges_failed, failed}} = perform_job(RangesWorker, %{})
    assert Enum.sort(failed) == Enum.sort(Engines.range_engines())
    assert_received {:fetch, _, %{engine: :bing, result: :transport_error}}
    assert Ranges.lookup(:bing, @inside_v4) == :in
  end

  test "an oversize body is refused" do
    Application.put_env(:kiln_cms, Ranges, Keyword.put(env(Ranges), :max_bytes, 1_024))
    big = list(for n <- 0..200, do: "45.143.#{div(n, 256)}.#{rem(n, 256)}/32")
    assert byte_size(big) > 1_024

    stub_all(fn _engine -> {200, big} end)

    assert {:error, _} = perform_job(RangesWorker, %{})
    assert_received {:fetch, _, %{engine: :duckduckgo, result: :too_large}}
    assert Ranges.lookup(:duckduckgo, @inside_v4) == :unknown
  end

  for {name, body, result} <- [
        {"too broad", ~s({"prefixes": [{"ipv4Prefix": "0.0.0.0/0"}]}), :too_broad},
        {"private", ~s({"prefixes": [{"ipv4Prefix": "10.0.0.0/24"}]}), :not_public},
        {"empty", ~s({"prefixes": []}), :no_prefixes},
        {"not JSON", "<html>moved</html>", :invalid}
      ] do
    test "a #{name} list is refused and the old one kept" do
      Ranges.put_fixture(:apple, [@v4])
      stub_all(fn _engine -> {200, unquote(body)} end)

      assert {:error, _} = perform_job(RangesWorker, %{})
      assert_received {:fetch, _, %{engine: :apple, result: unquote(result)}}
      assert Ranges.lookup(:apple, @inside_v4) == :in
      assert Ranges.lookup(:apple, {45, 143, 1, 1}) == :out
    end
  end

  test "a redirect is not followed" do
    stub_all(fn _engine -> {301, ""} end)

    assert {:error, _} = perform_job(RangesWorker, %{})
    assert_received {:fetch, _, %{engine: :google, result: :http_error}}
  end

  test "one vendor failing does not keep the others from installing" do
    stub_all(fn
      :google -> 503
      _engine -> {200, list([@v4])}
    end)

    assert {:error, {:crawler_ranges_failed, [:google]}} = perform_job(RangesWorker, %{})
    assert Ranges.lookup(:google, @inside_v4) == :unknown
    assert Ranges.lookup(:duckduckgo, @inside_v4) == :in
    assert Ranges.lookup(:bing, @inside_v4) == :in
  end

  test "a source SafeFetch refuses to dial is :blocked" do
    Application.put_env(
      :kiln_cms,
      Ranges,
      Keyword.put(env(Ranges), :sources, %{google: "https://127.0.0.1/list.json"})
    )

    stub_all(fn _engine -> {200, list([@v4])} end)

    assert {:error, {:crawler_ranges_failed, [:google]}} = perform_job(RangesWorker, %{})
    assert_received {:fetch, _, %{engine: :google, result: :blocked}}
  end

  for {name, key} <- [{"ranges", Ranges}, {"verification", CrawlerVerification}] do
    test "with #{name} off, no request is made" do
      test = self()

      Req.Test.stub(@stub, fn conn ->
        send(test, :requested)
        Req.Test.json(conn, %{})
      end)

      Application.put_env(
        :kiln_cms,
        unquote(key),
        Keyword.put(env(unquote(key)), :enabled, false)
      )

      assert perform_job(RangesWorker, %{}) == :ok
      refute_received :requested
      refute_received {:fetch, _, _}
    end
  end

  test "runs from the crontab every 6 hours" do
    assert App.cron_expression(:crawler_ranges_cron) == "17 */6 * * *"

    plugins = Keyword.fetch!(App.oban_config(), :plugins)
    assert {Oban.Plugins.Cron, cron} = List.keyfind(plugins, Oban.Plugins.Cron, 0)
    assert {"17 */6 * * *", RangesWorker} = List.keyfind(cron[:crontab], RangesWorker, 1)
  end

  # ---- helpers ---------------------------------------------------------------

  # Answers each vendor by the engine whose URL was asked for.
  defp stub_all(answer) do
    by_host = Map.new(Engines.range_engines(), &{URI.parse(Engines.range_source(&1)).host, &1})

    Req.Test.stub(@stub, fn conn ->
      case answer.(Map.fetch!(by_host, conn.host)) do
        {status, body} -> conn |> Plug.Conn.send_resp(status, body)
        :transport_error -> Req.Test.transport_error(conn, :econnrefused)
        status -> Plug.Conn.send_resp(conn, status, "")
      end
    end)
  end

  defp list(strings),
    do: Jason.encode!(%{"prefixes" => Enum.map(strings, &%{"ipv4Prefix" => &1})})

  defp env(key), do: Application.get_env(:kiln_cms, key, [])

  defp restore_env(key) do
    previous = Application.get_env(:kiln_cms, key)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, key, previous),
        else: Application.delete_env(:kiln_cms, key)
    end)
  end
end
