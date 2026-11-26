defmodule KilnCMS.Backups.Destination.SftpHostKeyAlertTest do
  @moduledoc """
  The `backup_host_key_changed` alert's window is the destination's own
  (#3201): two servers whose keys change inside one alert window each raise
  an alert naming them, while one server failing again inside the hour
  raises neither a second event nor a second alert. The rows stay platform
  alerts.

  `async: false`: it turns security alerts on, sets the alert window length
  and `BACKUP_SFTP_PRIVATE_HOSTS` (all application env, VM-global).
  """
  use KilnCMS.DataCase, async: false

  @moduletag :capture_log

  alias KilnCMS.Backups
  alias KilnCMS.Backups.Destination.Sftp
  alias KilnCMS.Backups.Destination.Sftp.HostKeyAlert
  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.Notification
  alias KilnCMS.Security
  alias KilnCMS.Security.{AlertDispatch, Alerts, AlertText}
  alias KilnCMS.Security.Changes.DeliverAlert
  alias KilnCMS.Test.{BackupSchedules, SecurityAlerts}

  @offered "SHA256:" <> String.duplicate("O", 43)
  @trusted "SHA256:" <> String.duplicate("T", 43)

  setup do
    SecurityAlerts.enable()
    # One long window, opened under a second ago: both mismatches fall in it.
    Application.put_env(:kiln_cms, :security_alert_window_ms, window())

    previous = Application.get_env(:kiln_cms, Sftp, [])
    Application.put_env(:kiln_cms, Sftp, Keyword.put(previous, :private_hosts, ["127.0.0.1"]))

    on_exit(fn ->
      Application.delete_env(:kiln_cms, :security_alert_window_ms)
      Application.put_env(:kiln_cms, Sftp, previous)
    end)

    %{platform: BackupSchedules.platform_admin()}
  end

  defp window, do: KilnCMS.Test.BudgetWindow.fresh_window_ms()

  defp destination!(actor) do
    Backups.create_backup_destination!(
      %{
        name: "NAS #{System.unique_integer([:positive])}",
        kind: "sftp",
        enabled: false,
        settings: %{
          "host" => "127.0.0.1",
          "port" => 2222,
          "username" => "kiln",
          "path" => "/backups/#{System.unique_integer([:positive])}"
        },
        secrets: %{"password" => "not-a-real-password"}
      },
      actor: actor
    )
  end

  defp mismatch!(row), do: :ok = HostKeyAlert.mismatch(row.id, "sftp", @offered, @trusted)

  defp alert_rows,
    do: Enum.filter(SecurityAlerts.dispatches(), &(&1["kind"] == "backup_host_key_changed"))

  defp events do
    Security.list_instance_events!(actor: BackupSchedules.platform_admin(), page: [limit: 100])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == :backup_destination_host_key_mismatch))
  end

  defp bells do
    Notification
    |> KilnCMS.Repo.all()
    |> Enum.filter(&(&1.event == :security_alert))
  end

  defp dispatch(raw) do
    %AlertDispatch{
      id: raw["id"],
      scope: raw["scope"],
      kind: raw["kind"],
      channel: :platform,
      org_id: raw["org_id"],
      window_index: raw["window_index"],
      window_started_at: utc(raw["window_started_at"]),
      window_ends_at: utc(raw["window_ends_at"]),
      notice: raw["notice"],
      inserted_at: utc(raw["inserted_at"])
    }
  end

  defp utc(%DateTime{} = at), do: at
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  test "two destinations in one window each raise an alert naming them", ctx do
    first = destination!(ctx.platform)
    second = destination!(ctx.platform)

    mismatch!(first)
    mismatch!(second)

    rows = alert_rows()
    assert length(rows) == 2

    # Both in the same alert window, each in its destination's own scope.
    assert rows |> Enum.map(& &1["window_index"]) |> Enum.uniq() |> length() == 1

    assert rows |> Enum.map(& &1["scope"]) |> Enum.sort() ==
             Enum.sort([HostKeyAlert.scope(first.id), HostKeyAlert.scope(second.id)])

    assert rows |> Enum.map(& &1["notice"]["destination"]) |> Enum.sort() ==
             Enum.sort([first.name, second.name])

    # Still platform alerts.
    assert Enum.all?(rows, &(&1["channel"] == "platform"))

    for raw <- rows do
      %{data: data, bell: bell} = DeliverAlert.build_plan(dispatch(raw), :alert)
      assert data.destination == raw["notice"]["destination"]
      assert Enum.map(bell, & &1.id) == [ctx.platform.id]

      assert AlertText.headline(AlertText.details(data)) ==
               "A backup server's host key changed: #{raw["notice"]["destination"]}"
    end

    SecurityAlerts.deliver()

    assert Enum.all?(alert_rows(), &match?(%{"alert_sent_at" => %{}}, &1))

    bells = bells()
    assert length(bells) == 2
    assert Enum.all?(bells, &(&1.content_type == Notifications.platform_alert_content_type()))
    assert Enum.all?(bells, &(&1.user_id == ctx.platform.id))
  end

  test "the same destination twice within the hour is one event and one alert", ctx do
    row = destination!(ctx.platform)

    mismatch!(row)
    mismatch!(row)

    assert [event] = events()
    assert event.target_id == row.id

    assert [%{"scope" => scope}] = alert_rows()
    assert scope == HostKeyAlert.scope(row.id)
  end

  test "a platform admin can't turn it off: turning off the optional kinds still sends it",
       ctx do
    refute :backup_host_key_changed in Alerts.platform_optional_kinds()

    Security.save_platform_alert_settings!(
      %{disabled_kinds: Enum.map(Alerts.platform_optional_kinds(), &Atom.to_string/1)},
      actor: ctx.platform
    )

    row = destination!(ctx.platform)
    mismatch!(row)
    SecurityAlerts.deliver()

    assert [%{"alert_sent_at" => %{}}] = alert_rows()
    assert [_bell] = bells()
  end

  test "with alerts off, the event is still recorded and no window is claimed", ctx do
    Application.put_env(:kiln_cms, KilnCMS.Security.Alerts, enabled: false)

    row = destination!(ctx.platform)
    mismatch!(row)

    assert [_event] = events()
    assert alert_rows() == []
  end
end
