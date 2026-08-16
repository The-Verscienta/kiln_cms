defmodule KilnCMS.Config.ReportTest do
  @moduledoc """
  The shared post-boot reporting path (#1126): every configuration warning
  that cannot be caught at config-provider time — `KilnCMS.Application`'s
  five `warn_if_*` boot checks, `KilnCMS.Branding.css_variables/1`'s AA
  check, and (since this issue) `KilnCMS.Config.Env.replay_collected/0`
  itself — goes through `warn/3`, so *how* a warning reaches an operator is
  one implementation, not seven copies that can each reach half way.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Config.Report

  import ExUnit.CaptureLog

  # Same technique `KilnCMS.Config.EnvTest` uses: `Sentry.Test`'s collector
  # needs `test_mode: true` globally, which this file has no business setting.
  # A `before_send` hook that captures the event and returns `nil` (dropping
  # it before anything is actually sent) works without that.
  defp capturing_sentry(fun) do
    test_pid = self()
    previous_dsn = Sentry.Config.dsn()
    previous_hook = Sentry.Config.before_send()

    on_exit(fn ->
      Sentry.Config.persist(dsn: previous_dsn, before_send: previous_hook)
    end)

    Sentry.Config.persist(
      dsn: "https://public@example.invalid/1",
      before_send: fn event ->
        send(test_pid, {:sentry_event, event})
        nil
      end
    )

    fun.()
  end

  test "logs the message as a warning" do
    log = capture_log(fn -> Report.warn("mailer", "no mail delivery is configured") end)

    assert log =~ "[warning]"
    assert log =~ "no mail delivery is configured"
  end

  test "also reports to Sentry — a bare Logger.warning alone never reaches it" do
    capturing_sentry(fn ->
      capture_log(fn -> Report.warn("strict_host", "TENANT_STRICT_HOST is off") end)
    end)

    assert_receive {:sentry_event, event}
    assert event.message.formatted == "TENANT_STRICT_HOST is off"
    assert event.level == :warning
  end

  test "groups by source, not by message, so a reworded warning stays one issue" do
    capturing_sentry(fn ->
      capture_log(fn -> Report.warn("branding_contrast", "brand colour #abc123 fails AA") end)
    end)

    assert_receive {:sentry_event, event}
    assert event.fingerprint == ["kiln-config-warning", "branding_contrast"]
  end

  test "extra rides along in the Sentry event" do
    capturing_sentry(fn ->
      capture_log(fn ->
        Report.warn("branding_contrast", "brand colour #abc123 fails AA", %{hex: "#abc123"})
      end)
    end)

    assert_receive {:sentry_event, event}
    assert event.extra[:hex] == "#abc123"
  end

  test "extra defaults to empty — a caller with nothing more to attach doesn't have to" do
    capturing_sentry(fn ->
      capture_log(fn -> Report.warn("mailer", "no mail delivery is configured") end)
    end)

    assert_receive {:sentry_event, event}
    assert event.extra == %{}
  end

  test "two different sources produce two different fingerprints" do
    capturing_sentry(fn ->
      capture_log(fn ->
        Report.warn("mailer", "no mail delivery is configured")
        Report.warn("strict_host", "TENANT_STRICT_HOST is off")
      end)
    end)

    assert_receive {:sentry_event, first}
    assert_receive {:sentry_event, second}

    assert [first.fingerprint, second.fingerprint] |> Enum.uniq() |> length() == 2
  end

  # #1288. The reads behind these warnings need the database, and both of them
  # guarded themselves with a bare `rescue` — which is why the exit case below
  # is the one that matters. A `rescue`-only guard passes every test that only
  # ever raises, and that is exactly how it survived until a test exited.
  describe "probe/2" do
    test "returns what the function returns when it answers" do
      assert Report.probe(:unknown, fn -> 3 end) == 3
    end

    test "takes the default when the read RAISES" do
      assert Report.probe(:unknown, fn -> raise DBConnection.ConnectionError, "refused" end) ==
               :unknown
    end

    test "takes the default when the read EXITS" do
      # The half a `rescue` never covered. `Repo.one/1` is a `:gen_server.call`
      # into the pool, and a call into a process that is not alive exits rather
      # than raising — which is what a pool still restarting after repeated
      # connect failures looks like from the caller.
      assert Report.probe(:unknown, fn -> exit(:noproc) end) == :unknown
      assert Report.probe(false, fn -> exit({:timeout, {GenServer, :call, []}}) end) == false
    end

    test "an exit from a real dead-process call is caught, not just a bare exit/1" do
      # `exit/1` above proves the clause; this proves the shape it exists for.
      # A `:gen_server.call` to a pid that has already stopped is the exact
      # thing `DBConnection.Holder.checkout/3` does.
      dead =
        spawn(fn -> :ok end)
        |> tap(fn pid ->
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _}
        end)

      assert Report.probe(:unknown, fn -> GenServer.call(dead, :anything) end) == :unknown
    end

    test "a THROW is not swallowed — that is a bug, not an unavailable database" do
      assert catch_throw(Report.probe(:unknown, fn -> throw(:boom) end)) == :boom
    end

    test "the default is the caller's, not a hardcoded false" do
      # `KilnCMSWeb.Tenant.org_count/0` needs `:unknown`, which `gap?/1` then
      # judges; `false` would be a different and wrong answer there.
      assert Report.probe(:unknown, fn -> exit(:noproc) end) == :unknown
      assert Report.probe(0, fn -> exit(:noproc) end) == 0
    end
  end
end
