defmodule KilnCMS.Security.Posture.Checks.CoreSecurityNoticesTest do
  @moduledoc """
  `core.security_notices` (#2522), answered from `Kiln.SecurityNotices`'
  cache only. A cold cache starts one background fetch (stubbed with
  `Req.Test`, so nothing leaves the machine) and answers unknown at once; the
  fetch is shared with `core.plugin_health`, so the two make one request.

  `async: false`: the cache is `:persistent_term`, the warmers node-wide
  registered names, and the switches application env.
  """
  use ExUnit.Case, async: false

  # The background fetch logs a warning when it finds the core affected.
  @moduletag :capture_log

  import ExUnit.CaptureLog
  import KilnCMS.PostureFixtures, only: [context: 1]
  import KilnCMS.Test.Eventually, only: [eventually: 1]

  alias Kiln.Plugins.Health
  alias Kiln.Plugins.Health.Notice
  alias Kiln.SecurityNotices
  alias Kiln.SecurityNotices.Core
  alias KilnCMS.Security.Posture.Checks.CoreSecurityNotices
  alias KilnCMS.Security.Posture.Checks.PluginHealth

  setup do
    notices = Application.get_env(:kiln_cms, SecurityNotices, [])
    updates = Application.get_env(:kiln_cms, Kiln.Updates, [])
    health = Application.get_env(:kiln_cms, Health, [])
    Health.clear_cache()

    on_exit(fn ->
      wait_for_warmers()
      Application.put_env(:kiln_cms, SecurityNotices, notices)
      Application.put_env(:kiln_cms, Kiln.Updates, updates)
      Application.put_env(:kiln_cms, Health, health)
      Health.clear_cache()
    end)

    :ok
  end

  # The feed is off in the test config; unset, it follows the update feed
  # (kilncms.dev's), as in production.
  defp enable do
    put(SecurityNotices, url: nil)
    put(Kiln.Updates, repo: nil, releases_url: nil, feed_url: nil)
  end

  defp put(key, pairs) do
    Application.put_env(
      :kiln_cms,
      key,
      Keyword.merge(Application.get_env(:kiln_cms, key, []), pairs)
    )
  end

  defp run, do: CoreSecurityNotices.run(context(nil))

  defp version, do: Kiln.Version.version()

  defp entry(id, fields) do
    %{"id" => id, "attributes" => %{"title" => "Notice #{id}", "custom_fields" => fields}}
  end

  # A notice covering every release up to and including this one.
  defp covering_entry do
    entry("1", %{
      "package" => "kiln_cms",
      "affected_versions" => "<= #{version()}",
      "severity" => "low",
      "advisory_id" => "GHSA-aaaa-bbbb-cccc"
    })
  end

  # Answers like kilncms.dev (and Hex, 404), and tells the test about every
  # request. Registered under both names so a plugin check's requests are
  # seen too.
  defp stub(entries \\ [], delay \\ 0) do
    test = self()

    fun = fn conn ->
      send(test, {:request, conn.host, conn.request_path})
      Process.sleep(delay)

      case conn.host do
        "kilncms.dev" -> Req.Test.json(conn, %{"data" => entries})
        _other -> Plug.Conn.send_resp(conn, 404, "")
      end
    end

    Req.Test.stub(SecurityNotices, fun)
    Req.Test.stub(Health, fun)
  end

  defp notice_requests do
    receive do
      {:request, "kilncms.dev", _path} -> 1 + notice_requests()
      {:request, _host, _path} -> notice_requests()
    after
      0 -> 0
    end
  end

  defp wait_for_warmers do
    eventually(fn ->
      is_nil(Process.whereis(SecurityNotices.warmer_name())) and
        is_nil(Process.whereis(Health.warmer_name()))
    end)
  end

  defp notice(overrides) do
    struct!(
      %Notice{
        id: "GHSA-6983-jfq8-485w",
        source: :kiln,
        packages: ["kiln_cms"],
        affected: ">= 1.3.0, < 1.3.2",
        patched: "1.3.2",
        severity: :high
      },
      overrides
    )
  end

  test "is a core deployment check, after core.release" do
    assert CoreSecurityNotices.id() == "core.security_notices"
    assert CoreSecurityNotices.scope() == :deployment
    assert Kiln.Security.Check.conformance(CoreSecurityNotices) == :ok

    core = KilnCMS.Security.Posture.Registry.core()
    index = Enum.find_index(core, &(&1 == CoreSecurityNotices))
    assert Enum.at(core, index - 1) == KilnCMS.Security.Posture.Checks.Release
  end

  describe "result/1" do
    test "an affected notice fails at any severity, naming its fix" do
      for severity <- [:low, :medium, :high, :critical, :unknown] do
        status = Core.status([notice(severity: severity)], "1.3.1")
        result = CoreSecurityNotices.result(status)

        assert result.status == :fail, "severity #{severity}"
        assert result.summary == "A security notice covers Kiln 1.3.1."
        assert [detail] = result.details
        assert detail =~ "GHSA-6983-jfq8-485w"
        assert detail =~ "fixed in 1.3.2"

        assert result.facts == %{
                 version: "1.3.1",
                 affected: 1,
                 unplaceable: 0,
                 notices: "GHSA-6983-jfq8-485w"
               }

        assert result.fix_path == "/editor/system"
        assert result.docs_url =~ "#security-notices-for-kiln"
      end
    end

    test "several affected notices are counted; one with no fix says so" do
      second = notice(id: "GHSA-2222-3333-4444", patched: "unknown")
      result = CoreSecurityNotices.result(Core.status([notice([]), second], "1.3.1"))

      assert result.status == :fail
      assert result.summary == "2 security notices cover Kiln 1.3.1."
      assert Enum.any?(result.details, &(&1 =~ "no fixed release is listed yet"))
      assert result.facts.notices == "GHSA-6983-jfq8-485w, GHSA-2222-3333-4444"
    end

    test "a notice that can't be placed is unknown, never a pass" do
      malformed = notice(affected: "unknown")
      shared = notice(id: "GHSA-2222-3333-4444", packages: ["kiln_cms", "kiln_seo"])
      result = CoreSecurityNotices.result(Core.status([malformed, shared], "1.3.1"))

      assert result.status == :unknown
      assert result.facts.unplaceable == 2

      assert result.details == [
               "GHSA-6983-jfq8-485w: its affected versions can't be read.",
               "GHSA-2222-3333-4444 names several packages; whether it covers Kiln can't be told."
             ]
    end

    test "an unreadable version with a notice naming the core is unknown" do
      result = CoreSecurityNotices.result(Core.status([notice([])], "0.0.0"))
      assert result.status == :unknown
      assert result.summary =~ "version"
    end

    # `patched_versions` is display text only: the publisher lists the lines
    # that have a fix, so it must never clear a version the range covers.
    test "an unfixed newer line fails although another line lists a fix" do
      unfixed = notice(affected: ">= 1.2.0, < 1.2.4; >= 1.3.0", patched: "1.2.4")
      result = CoreSecurityNotices.result(Core.status([unfixed], "1.3.1"))

      assert result.status == :fail
      assert result.facts.notices == "GHSA-6983-jfq8-485w"
    end

    test "a regression range after an older fix fails" do
      regression = notice(affected: ">= 1.5.0", patched: "1.3.2")
      assert %{status: :fail} = CoreSecurityNotices.result(Core.status([regression], "1.5.2"))
    end

    test "fixed, outside and plugin-only notices pass" do
      notices = [notice([]), notice(id: "PLUGIN", packages: ["kiln_seo"], affected: ">= 0.0.0")]
      result = CoreSecurityNotices.result(Core.status(notices, "1.3.2"))

      assert result.status == :pass
      assert result.summary == "No published security notice covers Kiln 1.3.2."
      assert result.details == []
      assert result.facts.affected == 0
    end
  end

  describe "run/1" do
    test "update checks turned off are not applicable, with no request and no warm" do
      enable()
      put(Kiln.Updates, enabled: false)
      stub()
      # Even a cache someone else filled is not read.
      SecurityNotices.put_cache({:ok, [notice(affected: ">= 0.0.0", patched: nil)]})

      assert %{status: :n_a, summary: summary} = run()
      assert summary =~ "KILN_UPDATE_CHECK=false"
      assert Process.whereis(SecurityNotices.warmer_name()) == nil
      assert notice_requests() == 0
    end

    test "a feed turned off is not applicable, with no request" do
      stub()
      assert %{status: :n_a, summary: summary} = run()
      assert summary =~ "KILN_SECURITY_NOTICES_URL"
      assert notice_requests() == 0
    end

    test "an invalid feed URL is unknown, with no request" do
      put(SecurityNotices, url: "not a url")
      stub()
      assert %{status: :unknown, summary: summary} = run()
      assert summary =~ "KILN_SECURITY_NOTICES_URL"
      assert notice_requests() == 0
    end

    test "a cold cache answers unknown at once, fetches once, and then answers" do
      enable()
      stub([covering_entry()])

      assert %{status: :unknown, facts: %{pending: true}, summary: summary} = run()
      assert summary =~ "reopen this page in a minute"

      assert_receive {:request, "kilncms.dev", _path}, 2000
      eventually(fn -> SecurityNotices.cached() != nil end)
      wait_for_warmers()

      assert %{status: :fail, facts: %{notices: "GHSA-aaaa-bbbb-cccc"}} = run()
      assert notice_requests() == 0
    end

    test "a failed fetch is unknown, never a pass" do
      enable()
      SecurityNotices.put_cache({:error, {:http_status, 503}})
      assert %{status: :unknown, summary: summary} = run()
      assert summary =~ "Could not reach the security notices feed"
    end

    test "a warm cache makes no request" do
      enable()
      stub()
      SecurityNotices.put_cache({:ok, []})

      assert %{status: :pass} = run()
      assert SecurityNotices.warm() == :cached
      assert notice_requests() == 0
    end

    test "the core is checked with no dependency plugin and plugin checks off" do
      enable()
      # Plugin health is off in the test config; the core's check does not
      # depend on it.
      refute Health.enabled?()
      stub()

      run()
      wait_for_warmers()
      assert notice_requests() == 1
      assert %{status: :pass} = run()
    end

    test "a fresh answer covering the core is logged once, by id" do
      enable()
      stub([covering_entry()])

      log =
        capture_log(fn ->
          run()
          eventually(fn -> SecurityNotices.cached() != nil end)
          wait_for_warmers()
          run()
          run()
        end)

      assert [_one] = Regex.scan(~r/is covered by security notice/, log)
      assert log =~ "GHSA-aaaa-bbbb-cccc"
      refute log =~ "http"
    end
  end

  # One request per node per TTL, whichever check asks first.
  describe "one fetch shared with core.plugin_health" do
    setup do
      enable()
      put(Health, enabled: true)
      :ok
    end

    defp run_plugins, do: PluginHealth.run(context(nil))

    defp settle do
      eventually(fn -> SecurityNotices.cached() != nil and Health.cached() != nil end)
      wait_for_warmers()
    end

    test "core first, then plugins" do
      stub()
      run()
      eventually(fn -> SecurityNotices.cached() != nil end)
      wait_for_warmers()
      run_plugins()
      settle()

      assert notice_requests() == 1
    end

    test "plugins first, then core" do
      stub()
      run_plugins()
      eventually(fn -> Health.cached() != nil end)
      wait_for_warmers()
      assert %{status: :pass} = run()
      settle()

      assert notice_requests() == 1
    end

    test "both at once" do
      # Slow enough that both warmers are in flight together.
      stub([], 100)
      run()
      run_plugins()
      settle()

      assert notice_requests() == 1
      assert %{status: :pass} = run()
    end
  end
end
