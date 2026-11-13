defmodule KilnCMS.Security.FailedSignInAlertTest do
  @moduledoc """
  The `failed_sign_ins` alert (#2245) through `Recorder.record_sampled/2`, as
  every failed sign-in is recorded: a per-site tally, the one attempt that
  reaches the threshold recorded unsampled and alerted once, and the window's
  total in the summary.

  `async: false`: alerts are turned on and the window length is set
  (`Application.put_env`).
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Notifications.Notification
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.Security.Alerts
  alias KilnCMS.Security.Recorder
  alias KilnCMS.Test.SecurityAlerts

  @moduletag :capture_log

  setup do
    SecurityAlerts.enable()
    Application.put_env(:kiln_cms, :security_alert_window_ms, window())
    on_exit(fn -> Application.delete_env(:kiln_cms, :security_alert_window_ms) end)

    org = org("failed-sign-ins")

    admin =
      Ash.Seed.seed!(Accounts.User, %{
        email: "fsi-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org.id,
      user_id: admin.id,
      role: :admin
    })

    %{org: org, admin: admin}
  end

  defp window, do: KilnCMS.Test.BudgetWindow.fresh_window_ms()

  defp enable!(ctx) do
    CMS.save_site_security_alerts!(%{disabled_kinds: []}, actor: ctx.admin, tenant: ctx.org.id)
    Repo.query!("DELETE FROM security_alert_dispatches")
  end

  defp fail(org_id, n, ip_fun \\ fn _ -> "198.51.100.9" end) do
    for i <- 1..n do
      :ok = Recorder.record_sampled(:sign_in_failed, tenant: org_id, request: %{ip: ip_fun.(i)})
    end
  end

  defp alerts, do: Enum.filter(SecurityAlerts.dispatches(), &(&1["kind"] == "failed_sign_ins"))

  defp recorded(org_id) do
    # authorize?: false — reading the log back in a test.
    Security.list_events!(tenant: org_id, authorize?: false)
    |> Enum.filter(&(&1.type == :sign_in_failed))
  end

  test "nine is nothing; the tenth alerts once; thirty more are the summary's", ctx do
    enable!(ctx)

    fail(ctx.org.id, 9)
    assert alerts() == []

    fail(ctx.org.id, 1)
    assert [alert] = alerts()
    assert alert["threshold_count"] == Alerts.failed_sign_in_threshold()
    assert alert["scope"] == ctx.org.id

    {_count, index} =
      KilnCMS.Accounts.ThrottleStore.count("probe-#{ctx.org.id}", ctx.org.id, window())

    assert alert["window_index"] == index

    fail(ctx.org.id, 30)
    assert [_one] = alerts()

    # Sampled per address, but the threshold-th attempt is always written.
    assert length(recorded(ctx.org.id)) == 6

    SecurityAlerts.deliver()

    assert [%{excerpt: "Failed sign-ins reached the alert threshold" <> _}] =
             Repo.all(Notification)

    SecurityAlerts.close_window(alert["id"])
    SecurityAlerts.deliver()

    excerpts = Notification |> Repo.all() |> Enum.map(& &1.excerpt) |> Enum.sort()

    assert excerpts == [
             "Failed sign-ins reached the alert threshold (from 198.51.100.0/24)",
             "Failed sign-ins reached the alert threshold: 40 in this alert window"
           ]
  end

  # The tally counts when it cannot read the settings; delivery must read the
  # same failure the same way, or the claimed alert is stamped sent unsent.
  test "a claimed alert is delivered when the settings cannot be read", ctx do
    enable!(ctx)
    fail(ctx.org.id, Alerts.failed_sign_in_threshold())
    assert [_alert] = alerts()

    KilnCMS.OrgSettings.with_actor(%{id: "nobody"}, fn -> SecurityAlerts.deliver() end)

    assert [%{user_id: user_id, excerpt: "Failed sign-ins reached the alert threshold" <> _}] =
             Repo.all(Notification)

    assert user_id == ctx.admin.id
  end

  test "forty addresses are one tally, and another site's are not in it", ctx do
    enable!(ctx)
    other = org("failed-sign-ins-b")

    fail(other.id, 9, &"192.0.2.#{&1}")
    fail(ctx.org.id, 9, &"192.0.2.#{&1}")
    assert alerts() == []

    fail(ctx.org.id, 31, &"192.0.2.#{&1 + 9}")
    assert [%{"scope" => scope}] = alerts()
    assert scope == ctx.org.id
  end

  # #2639: the tally is sharded, so attempts arriving together can each read a
  # total at or past the threshold. One of them alerts on this node; the rest
  # are counted and sampled like any other.
  test "forty at once alert once, and only one of them is recorded unsampled", ctx do
    enable!(ctx)

    1..40
    |> Enum.map(fn _ ->
      Task.async(fn ->
        Recorder.record_sampled(:sign_in_failed,
          tenant: ctx.org.id,
          request: %{ip: "198.51.100.9"}
        )
      end)
    end)
    |> Task.await_many(10_000)

    assert [alert] = alerts()
    assert alert["threshold_count"] >= Alerts.failed_sign_in_threshold()
    # Five sampled for the one address, plus the attempt that alerted.
    assert length(recorded(ctx.org.id)) == 6

    assert Alerts.failed_sign_in_total(ctx.org.id, alert["window_index"]) == 40
  end

  test "charges arriving together: exactly one is the threshold", ctx do
    enable!(ctx)
    threshold = Alerts.failed_sign_in_threshold()

    results =
      1..40
      |> Enum.map(fn _ -> Task.async(fn -> Alerts.charge_failed_sign_in(ctx.org.id) end) end)
      |> Task.await_many(10_000)

    assert [{:threshold, idx, count}] = Enum.filter(results, &match?({:threshold, _, _}, &1))
    assert count >= threshold
    assert Enum.count(results, &(&1 == :counted)) == 39
    assert Alerts.failed_sign_in_total(ctx.org.id, idx) == 40
  end

  test "the summary counts every shard, and a previous release's unsharded row", ctx do
    enable!(ctx)
    bucket = Alerts.failed_sign_in_bucket()

    # A node of the previous release counted three on the unsharded key.
    for _ <- 1..3, do: KilnCMS.Accounts.ThrottleStore.count(bucket, ctx.org.id, window())

    fail(ctx.org.id, Alerts.failed_sign_in_threshold() + 7)
    assert [alert] = alerts()
    assert alert["threshold_count"] == Alerts.failed_sign_in_threshold()

    %{rows: [[rows]]} =
      Repo.query!("SELECT count(*) FROM throttle_counters WHERE bucket = $1", [bucket])

    assert rows > 2

    SecurityAlerts.deliver()
    SecurityAlerts.close_window(alert["id"])
    SecurityAlerts.deliver()

    assert Enum.any?(
             Repo.all(Notification),
             &(&1.excerpt ==
                 "Failed sign-ins reached the alert threshold: 20 in this alert window")
           )
  end

  test "off by default: nothing is counted and nothing alerts", ctx do
    fail(ctx.org.id, 20)

    assert alerts() == []

    assert Alerts.failed_sign_in_total(
             ctx.org.id,
             div(System.system_time(:millisecond), window())
           ) == nil
  end
end

defmodule KilnCMS.Security.FailedSignInTallyFallbackTest do
  @moduledoc """
  The failed-sign-in tally with no database (#2639): the settings cannot be
  read, so the tally counts (the direction that can still alert), on this
  node's fallback, and the threshold is still reached. Sync and not a
  `DataCase`: the sandbox is put in `:manual` mode with nothing checked out.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Security.Alerts
  alias KilnCMS.Test.BudgetWindow

  @moduletag :capture_log

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(KilnCMS.Repo, :manual)
    :ok
  end

  test "an unreachable store still reaches the threshold, once" do
    org_id = Ecto.UUID.generate()
    window = BudgetWindow.fresh_window_ms()
    threshold = Alerts.failed_sign_in_threshold()

    results =
      for _ <- 1..(threshold + 3), do: Alerts.charge_failed_sign_in(org_id, window_ms: window)

    assert Enum.take(results, threshold - 1) |> Enum.all?(&(&1 == :counted))
    assert {:threshold, idx, ^threshold} = Enum.at(results, threshold - 1)
    assert idx == div(System.system_time(:millisecond), window)
    assert Enum.drop(results, threshold) |> Enum.all?(&(&1 == :counted))
  end
end
