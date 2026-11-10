defmodule Kiln.Plugins.HealthTest do
  @moduledoc """
  The plugin health check's orchestration (#2244): when it asks hex.pm and the
  notices feed, what it caches, and that nothing it cannot confirm reads as OK.
  Every request goes to a `Req.Test` stub (`config/test.exs`); the notices
  feed is asked through `Kiln.SecurityNotices`, so each stub is registered
  under both names.
  """
  # async: false - the cache is a :persistent_term shared VM-wide, and these
  # cases flip `Kiln.Plugins.Health`, `Kiln.SecurityNotices` and `Kiln.Updates`
  # app env.
  use ExUnit.Case, async: false

  # A check that finds a failing plugin logs a warning; several cases do.
  @moduletag :capture_log

  alias Kiln.Plugins.Health
  alias Kiln.Plugins.Health.Installed
  alias Kiln.Plugins.Health.Report
  alias Kiln.SecurityNotices

  @fixtures Path.expand("../../support/fixtures/hex", __DIR__)
  @locked "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684"
  @tampered "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30685"

  setup do
    health = Application.get_env(:kiln_cms, Health, [])
    notices = Application.get_env(:kiln_cms, SecurityNotices, [])
    updates = Application.get_env(:kiln_cms, Kiln.Updates, [])

    Health.clear_cache()

    on_exit(fn ->
      Application.put_env(:kiln_cms, Health, health)
      Application.put_env(:kiln_cms, SecurityNotices, notices)
      Application.put_env(:kiln_cms, Kiln.Updates, updates)
      Health.clear_cache()
    end)

    :ok
  end

  defp put_health(pairs) do
    Application.put_env(
      :kiln_cms,
      Health,
      Keyword.merge(Application.get_env(:kiln_cms, Health, []), pairs)
    )
  end

  defp put_notices(pairs) do
    Application.put_env(
      :kiln_cms,
      SecurityNotices,
      Keyword.merge(Application.get_env(:kiln_cms, SecurityNotices, []), pairs)
    )
  end

  defp put_updates(pairs) do
    Application.put_env(
      :kiln_cms,
      Kiln.Updates,
      Keyword.merge(Application.get_env(:kiln_cms, Kiln.Updates, []), pairs)
    )
  end

  # The notices feed is off in the test config; unset, it follows the update
  # feed (kilncms.dev's), as in production.
  defp enable do
    put_health(enabled: true)
    put_notices(url: nil)
  end

  # Both names: Hex is asked through `Kiln.Plugins.Health`'s options, the
  # notices feed through `Kiln.SecurityNotices`'s.
  defp stub_both(fun) do
    Req.Test.stub(Health, fun)
    Req.Test.stub(SecurityNotices, fun)
  end

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp hex_plugin(overrides \\ %{}) do
    struct!(
      %Installed{
        plugin: FakeHexPlugin,
        name: "Fake jason plugin",
        app: :jason,
        source: :hex,
        package: "jason",
        version: "1.4.5",
        repo: "hexpm",
        outer_checksum: @locked,
        sdk_requirement: nil
      },
      overrides
    )
  end

  defp overlay_plugin do
    %Installed{
      plugin: KilnCMS.FixturePlugin,
      name: "Fixture",
      app: :kiln_cms,
      source: :overlay,
      version: "0.1.0"
    }
  end

  defp path_plugin do
    %Installed{
      plugin: KilnDepFixture.Plugin,
      name: "Dep fixture",
      app: :kiln_dep_fixture,
      source: :path,
      version: "0.1.0",
      sdk_requirement: "~> 1.4"
    }
  end

  # Answers like hex.pm and kilncms.dev, and tells the test about every request.
  defp stub(opts \\ []) do
    test = self()
    release = Map.merge(fixture("jason_release_1.4.5.json"), Keyword.get(opts, :release, %{}))
    package = fixture("jason_package.json")
    notices = Keyword.get(opts, :notices, %{"data" => []})
    hex = Keyword.get(opts, :hex)

    stub_both(fn conn ->
      send(test, {:request, conn.host, conn.request_path})

      case {conn.host, conn.request_path} do
        {"hex.pm", path} when is_function(hex, 2) ->
          hex.(conn, path)

        {"hex.pm", "/api/packages/jason"} ->
          Req.Test.json(conn, package)

        {"hex.pm", "/api/packages/jason/releases/1.4.5"} ->
          Req.Test.json(conn, release)

        {"kilncms.dev", "/api/json/entries/published"} when is_function(notices, 1) ->
          notices.(conn)

        {"kilncms.dev", "/api/json/entries/published"} ->
          Req.Test.json(conn, notices)

        _other ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  defp requests do
    receive do
      {:request, host, path} -> [{host, path} | requests()]
    after
      0 -> []
    end
  end

  describe "the mutation, end to end" do
    test "a release whose checksum changed on Hex fails" do
      enable()
      stub(release: %{"checksum" => @tampered})

      assert %Report{state: :fresh, plugins: [status]} =
               Health.check(installed: [hex_plugin()], force: true)

      assert {:mismatch, %{locked: @locked, registry: @tampered}} = status.integrity
      assert status.overall == :fail
    end

    test "the recorded release passes" do
      enable()
      stub()

      assert %Report{state: :fresh, notices: :ok, plugins: [status]} =
               Health.check(installed: [hex_plugin()])

      assert status.integrity == :ok
      assert status.overall == :ok
      assert {"hex.pm", "/api/packages/jason/releases/1.4.5"} in requests()
    end

    test "a fresh failure is logged once" do
      enable()
      stub(release: %{"checksum" => @tampered})

      log =
        ExUnit.CaptureLog.capture_log(fn -> Health.check(installed: [hex_plugin()]) end)

      assert log =~ "Fake jason plugin (changed on Hex since this build)"
    end
  end

  describe "offline and failing sources are unknown, never ok" do
    defp hex_answering(fun), do: stub(hex: fn conn, _path -> fun.(conn) end)

    test "a transport error" do
      enable()
      hex_answering(&Req.Test.transport_error(&1, :econnrefused))

      assert %Report{state: :partial, plugins: [status]} = Health.check(installed: [hex_plugin()])
      assert status.integrity == :unknown
      assert status.overall == :unknown
    end

    test "a fetch that crashes reads as unknown and leaves the caller standing" do
      enable()

      stub_both(fn conn ->
        if conn.host == "hex.pm", do: raise("boom"), else: exit(:boom)
      end)

      assert %Report{state: :partial, notices: :unknown, plugins: [status]} =
               Health.check(installed: [hex_plugin()])

      assert status.integrity == :unknown
      assert status.overall == :unknown
      assert Process.alive?(self())
    end

    test "a 503" do
      enable()
      hex_answering(&Plug.Conn.send_resp(&1, 503, "down"))

      assert %Report{plugins: [%{integrity: :unknown, overall: :unknown}]} =
               Health.check(installed: [hex_plugin()])
    end

    test "a body that isn't JSON" do
      enable()
      hex_answering(&Plug.Conn.send_resp(&1, 200, "<html>"))

      assert %Report{plugins: [%{integrity: :unknown, overall: :unknown}]} =
               Health.check(installed: [hex_plugin()])
    end

    test "a body over the cap" do
      enable()
      hex_answering(&Plug.Conn.send_resp(&1, 200, String.duplicate("x", 2_000_001)))

      assert %Report{plugins: [%{integrity: :unknown, overall: :unknown}]} =
               Health.check(installed: [hex_plugin()])
    end

    test "a 404 is an answer: not on Hex, which warns" do
      enable()
      hex_answering(&Plug.Conn.send_resp(&1, 404, ""))

      assert %Report{state: :fresh, plugins: [status]} = Health.check(installed: [hex_plugin()])
      assert status.integrity == :not_found
      assert status.overall == :warn
    end

    test "a failure is cached rather than retried on every read" do
      enable()
      hex_answering(&Plug.Conn.send_resp(&1, 503, "down"))

      Health.check(installed: [hex_plugin()])
      assert [_ | _] = requests()

      assert %Report{state: :partial} = Health.check(installed: [hex_plugin()])
      assert requests() == []
    end

    test "the notices feed down with Hex up leaves advisories unknown" do
      enable()
      stub(notices: &Plug.Conn.send_resp(&1, 500, ""))

      assert %Report{state: :partial, notices: :unknown, plugins: [status]} =
               Health.check(installed: [hex_plugin()])

      assert status.integrity == :ok
      assert status.advisories == {:unknown, []}
      assert status.overall == :unknown
    end

    test "a matched security notice from the feed fails the plugin" do
      enable()

      stub(
        notices: %{
          "data" => [
            %{
              "id" => "1",
              "attributes" => %{
                "title" => "jason is broken",
                "custom_fields" => %{
                  "package" => "jason",
                  "affected_versions" => ">= 1.0.0, < 1.5.0",
                  "severity" => "critical",
                  "advisory_id" => "GHSA-aaaa-bbbb-cccc"
                }
              }
            }
          ]
        }
      )

      assert %Report{plugins: [status]} = Health.check(installed: [hex_plugin()])
      assert {:ok, [%{id: "GHSA-aaaa-bbbb-cccc", severity: :critical}]} = status.advisories
      assert status.overall == :fail
    end
  end

  describe "when nothing may or need be asked" do
    test "disabled makes no request and still checks the SDK locally" do
      stub()

      assert %Report{state: :disabled, notices: :disabled, checked_at: nil, plugins: plugins} =
               Health.check(installed: [hex_plugin(), path_plugin()], force: true)

      assert requests() == []
      assert Enum.map(plugins, & &1.integrity) == [:disabled, {:unverifiable, :path}]
    end

    test "a deployment with no dependency plugins makes no request" do
      enable()
      stub()

      assert %Report{state: :nothing_to_check, plugins: [status]} =
               Health.check(installed: [overlay_plugin()], force: true)

      assert status.overall == :not_applicable
      assert requests() == []
    end

    test "a git or path plugin alone asks only the notices feed" do
      enable()
      stub()

      assert %Report{state: :fresh, plugins: [status]} = Health.check(installed: [path_plugin()])
      assert requests() == [{"kilncms.dev", "/api/json/entries/published"}]
      assert status.overall == :unverifiable
    end

    test "an invalid package name is never requested" do
      enable()
      stub()

      for package <- ["../evil", "Jason", "jason/releases", "", "jason?x=1"] do
        Health.clear_cache()

        assert %Report{plugins: [status]} =
                 Health.check(installed: [hex_plugin(package: package)])

        assert status.integrity == :unknown
        assert Enum.filter(requests(), &match?({"hex.pm", _}, &1)) == []
      end
    end

    test "an unparseable version is never requested" do
      enable()
      stub()

      Health.check(installed: [hex_plugin(version: "1.4.5/../../x")])
      assert Enum.filter(requests(), &match?({"hex.pm", _}, &1)) == []
    end
  end

  describe "cached/1" do
    test "never touches the network: a cold cache is nil" do
      enable()
      stub()

      assert Health.cached(installed: [hex_plugin()]) == nil
      assert requests() == []
    end

    test "answers from what check/1 fetched" do
      enable()
      stub()
      Health.check(installed: [hex_plugin()])
      _ = requests()

      assert %Report{state: :fresh, plugins: [%{overall: :ok}]} =
               Health.cached(installed: [hex_plugin()])

      assert requests() == []
    end

    test "answers disabled and nothing-to-check without a request" do
      stub()
      assert %Report{state: :disabled} = Health.cached(installed: [hex_plugin()])

      enable()
      assert %Report{state: :nothing_to_check} = Health.cached(installed: [overlay_plugin()])
      assert requests() == []
    end

    test "re-evaluates at the time of reading, so staleness does not freeze" do
      enable()
      stub()
      Health.check(installed: [hex_plugin()])

      later = DateTime.add(DateTime.utc_now(), 5 * 365, :day)
      assert %Report{plugins: [status]} = Health.cached(installed: [hex_plugin()], now: later)
      assert [{:stale, _}] = status.abandonment
    end
  end

  describe "forcing" do
    test "is floored at one request round a minute" do
      enable()
      stub()

      Health.check(installed: [hex_plugin()], force: true)
      assert [_ | _] = requests()

      Health.check(installed: [hex_plugin()], force: true)
      assert requests() == []
    end

    test "bypasses a fresh cache the first time" do
      enable()
      stub()
      Health.put_cache(%{hex: %{"jason" => {:error, :timeout}}, notices: {:ok, []}})

      assert %Report{state: :fresh} = Health.check(installed: [hex_plugin()], force: true)
      assert [_ | _] = requests()
    end
  end

  describe "warm/0" do
    test "is disabled when checks are off" do
      assert Health.warm() == :disabled
    end

    test "answers :cached when the cache is warm" do
      enable()
      Health.put_cache(%{hex: %{}, notices: {:ok, []}})
      assert Health.warm() == :cached
    end

    test "answers :in_flight while a warmer runs" do
      enable()
      Process.register(self(), Health.warmer_name())

      try do
        assert Health.warm() == :in_flight
      after
        Process.unregister(Health.warmer_name())
      end
    end
  end

  describe "enabled?/0" do
    test "unset follows the update check" do
      put_health(enabled: nil)
      put_updates(enabled: false)
      refute Health.enabled?()

      put_updates(enabled: true)
      assert Health.enabled?()
    end

    test "an explicit value wins either way" do
      put_updates(enabled: false)
      put_health(enabled: true)
      assert Health.enabled?()

      put_updates(enabled: true)
      put_health(enabled: false)
      refute Health.enabled?()
    end

    test "KILN_UPDATE_CHECK=false with no plugin setting makes no request" do
      put_health(enabled: nil)
      put_updates(enabled: false)
      stub()

      assert %Report{state: :disabled} = Health.check(installed: [hex_plugin()], force: true)
      assert requests() == []
    end
  end

  describe "the notices feed's URL" do
    setup do
      put_updates(repo: nil, releases_url: nil, feed_url: nil)
      :ok
    end

    test "a fork asks Hex but not kilncms.dev" do
      enable()
      put_updates(repo: "someone/fork")
      stub()

      assert %Report{notices: :disabled, plugins: [%{overall: :ok}]} =
               Health.check(installed: [hex_plugin()])

      refute Enum.any?(requests(), &match?({"kilncms.dev", _}, &1))
    end
  end

  describe "stale_after_months/0" do
    test "defaults to 24 and reads a configured positive integer" do
      put_health(stale_after_months: nil)
      assert Health.stale_after_months() == 24

      put_health(stale_after_months: 6)
      assert Health.stale_after_months() == 6
    end
  end

  describe "the real install" do
    test "classifies the test suite's plugins without a request" do
      enable()
      stub()

      installed = Installed.all()

      assert %Installed{source: :overlay} =
               Enum.find(installed, &(&1.plugin == KilnCMS.FixturePlugin))

      assert %Installed{source: :path, app: :kiln_dep_fixture, sdk_requirement: "~> 1.4"} =
               Enum.find(installed, &(&1.plugin == KilnDepFixture.Plugin))

      assert requests() == []
    end
  end
end
