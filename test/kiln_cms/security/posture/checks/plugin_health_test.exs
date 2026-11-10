defmodule KilnCMS.Security.Posture.Checks.PluginHealthTest do
  @moduledoc """
  `core.plugin_health` (#2244), answered from `Kiln.Plugins.Health`'s cache
  only. Remote data comes from a `Req.Test` stub serving recorded hex.pm
  documents, so nothing leaves the machine; the notices feed is asked through
  `Kiln.SecurityNotices`, so each stub is registered under both names.

  `async: false`: the cache is `:persistent_term` and the switch application
  env, both node-wide.
  """
  use ExUnit.Case, async: false

  # A check that finds a failing plugin logs a warning; the background check
  # logs its answer.
  @moduletag :capture_log

  import KilnCMS.PostureFixtures, only: [context: 1]
  import KilnCMS.Test.Eventually, only: [eventually: 1]

  alias Kiln.Plugins.Health
  alias Kiln.Plugins.Health.Installed
  alias Kiln.SecurityNotices
  alias KilnCMS.Security.Posture.Checks.PluginHealth

  @fixtures Path.expand("../../../../support/fixtures/hex", __DIR__)
  @locked "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684"
  @tampered "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30685"

  setup do
    original = Application.get_env(:kiln_cms, Health, [])
    notices = Application.get_env(:kiln_cms, SecurityNotices, [])
    Health.clear_cache()

    on_exit(fn ->
      Application.put_env(:kiln_cms, Health, original)
      Application.put_env(:kiln_cms, SecurityNotices, notices)
      Health.clear_cache()
    end)

    :ok
  end

  defp enable do
    Application.put_env(
      :kiln_cms,
      Health,
      Keyword.put(Application.get_env(:kiln_cms, Health, []), :enabled, true)
    )

    # The notices feed is off in the test config; unset, it follows the update
    # feed (kilncms.dev's), as in production.
    Application.put_env(
      :kiln_cms,
      SecurityNotices,
      Keyword.put(Application.get_env(:kiln_cms, SecurityNotices, []), :url, nil)
    )
  end

  # Both names: Hex is asked through `Kiln.Plugins.Health`'s options, the
  # notices feed through `Kiln.SecurityNotices`'s.
  defp stub_both(fun) do
    Req.Test.stub(Health, fun)
    Req.Test.stub(SecurityNotices, fun)
  end

  defp run, do: PluginHealth.run(context(nil))

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp hex_plugin do
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
    }
  end

  defp git_plugin(overrides \\ %{}) do
    struct!(
      %Installed{
        plugin: FakeGitPlugin,
        name: "Fake git plugin",
        app: :fake_git_plugin,
        source: :git,
        version: "0.3.0",
        git_url: "https://example.com/fake_git_plugin.git",
        git_ref: "0123456789abcdef0123456789abcdef01234567",
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

  # Answers like hex.pm and kilncms.dev, and tells the test about every request.
  defp stub(opts \\ []) do
    test = self()
    release = Map.merge(fixture("jason_release_1.4.5.json"), Keyword.get(opts, :release, %{}))
    package = fixture("jason_package.json")
    notices = Keyword.get(opts, :notices, %{"data" => []})

    stub_both(fn conn ->
      send(test, {:request, conn.host, conn.request_path})

      case {conn.host, conn.request_path} do
        {"hex.pm", "/api/packages/jason"} -> Req.Test.json(conn, package)
        {"hex.pm", "/api/packages/jason/releases/1.4.5"} -> Req.Test.json(conn, release)
        {"kilncms.dev", "/api/json/entries/published"} -> Req.Test.json(conn, notices)
        _other -> Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  defp from_cache(installed), do: PluginHealth.result(Health.cached(installed: installed))

  test "is a core deployment check" do
    assert PluginHealth.id() == "core.plugin_health"
    assert PluginHealth.scope() == :deployment
    assert Kiln.Security.Check.conformance(PluginHealth) == :ok
    assert PluginHealth in KilnCMS.Security.Posture.Registry.core()
  end

  describe "the mutation, end to end" do
    test "a package that changed on Hex since this build fails the posture check" do
      enable()
      stub(release: %{"checksum" => @tampered})

      Health.check(installed: [hex_plugin()], force: true)
      result = from_cache([hex_plugin()])

      assert result.status == :fail
      assert result.summary =~ "1 plugin has problems"

      assert Enum.any?(
               result.details,
               &(&1 =~ "Fake jason plugin: the package Hex publishes at 1.4.5 differs")
             )

      assert result.facts.fail == 1
      assert result.fix_path == "/editor/system"
    end

    test "the recorded release passes" do
      enable()
      stub()

      Health.check(installed: [hex_plugin()], force: true)
      result = from_cache([hex_plugin()])

      assert result.status == :pass
      assert result.summary =~ "Every plugin matches Hex"
      assert result.details == []
    end
  end

  test "a git plugin with a clean feed and SDK passes, saying how far the check reached" do
    enable()
    stub()

    Health.check(installed: [git_plugin()], force: true)
    result = from_cache([git_plugin()])

    assert result.status == :pass
    refute result.summary =~ "matches Hex"

    assert result.details == [
             "1 plugin comes from git or a path; checked for security notices and SDK support only."
           ]

    assert result.facts.unverifiable == 1
  end

  test "a matched low-severity notice warns, naming it" do
    enable()

    stub(
      notices: %{
        "data" => [
          %{
            "id" => "1",
            "attributes" => %{
              "title" => "A small problem",
              "custom_fields" => %{
                "package" => "fake_git_plugin",
                "affected_versions" => "< 0.4.0",
                "severity" => "low",
                "advisory_id" => "KILN-2026-0001"
              }
            }
          }
        ]
      }
    )

    Health.check(installed: [git_plugin()], force: true)
    result = from_cache([git_plugin()])

    assert result.status == :warn
    assert "Fake git plugin 0.3.0: security notice KILN-2026-0001 (low)." in result.details
  end

  test "an unreachable feed is unknown, never a pass" do
    enable()

    stub_both(&Req.Test.transport_error(&1, :econnrefused))

    Health.check(installed: [git_plugin()], force: true)
    result = from_cache([git_plugin()])

    assert result.status == :unknown
    assert result.details == ["Fake git plugin could not be checked."]
  end

  test "no plugin from Hex, git or a path is not applicable, and asks nothing" do
    enable()
    stub_both(fn conn -> flunk("a request was made: #{conn.request_path}") end)

    assert %{status: :n_a} = PluginHealth.result(Health.check(installed: [overlay_plugin()]))
  end

  describe "checks turned off" do
    test "are not applicable, and run without a request" do
      stub_both(fn conn -> flunk("a request was made: #{conn.request_path}") end)

      assert %{status: :n_a, summary: summary} = run()
      assert summary =~ "turned off"
    end

    test "still warn about an SDK this Kiln does not bundle" do
      plugin = git_plugin(sdk_requirement: "~> 99.0")
      result = PluginHealth.result(Health.check(installed: [plugin]))

      assert result.status == :warn
      assert [detail] = result.details
      assert detail =~ "Fake git plugin needs kiln_plugin ~> 99.0"
    end
  end

  test "a cold cache answers unknown at once and warms the cache in the background" do
    enable()
    stub()

    assert %{status: :unknown, facts: %{pending: true}, summary: summary} = run()
    assert summary =~ "reopen this page in a minute"

    # The installed fixture plugins include a path dependency, so the
    # background check asked the notices feed and cached the answer.
    assert_receive {:request, "kilncms.dev", _path}, 2000
    eventually(fn -> Health.cached() != nil end)
    refute Map.has_key?(run().facts, :pending)
  end
end
