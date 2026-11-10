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

  test "off by default: nothing is counted and nothing alerts", ctx do
    fail(ctx.org.id, 20)

    assert alerts() == []

    assert KilnCMS.Accounts.ThrottleStore.window_count(
             Alerts.failed_sign_in_bucket(),
             ctx.org.id,
             div(System.system_time(:millisecond), window())
           ) == nil
  end
end
