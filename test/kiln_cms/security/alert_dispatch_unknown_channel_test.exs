defmodule KilnCMS.Security.AlertDispatchUnknownChannelTest do
  @moduledoc """
  What a release does with a dispatch row whose `channel` it cannot load
  (#3496): v1.13.0 with a `platform_notice` row written by a newer release,
  after a rollback or on an old node in a rolling deploy.

  The row's channel is a string built at run time, so it is no atom this VM
  knows, as `"platform_notice"` is no atom v1.13.0 knows. The real
  scheduler and worker run it, ten attempts, and the log is captured.

  `async: false`: the triggers are drained in this process.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Accounts
  alias KilnCMS.Repo
  alias KilnCMS.Test.SecurityAlerts

  @worker "KilnCMS.Security.AlertDispatch.AshOban.Worker.DeliverAlert"

  defp unknown_channel do
    channel = "zz_unknown_channel_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(channel) end
    channel
  end

  defp insert_row!(channel) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO security_alert_dispatches
          (id, scope, kind, channel, org_id, window_index, window_started_at, window_ends_at,
           notice, expires_at, inserted_at)
        SELECT w.id, 'zz:' || w.id::text, 'alerts_silenced', $1::text, $2::text::uuid, 0,
               w.now, w.now, '{}'::jsonb, w.now + interval '1 day', w.now
        FROM (SELECT gen_random_uuid() AS id, clock_timestamp() AT TIME ZONE 'UTC' AS now) AS w
        RETURNING id::text
        """,
        [channel, Accounts.default_org_id()]
      )

    id
  end

  defp jobs do
    Oban.Job |> Repo.all() |> Enum.filter(&(&1.worker == @worker))
  end

  defp attach_failures do
    test = self()
    id = "unknown-channel-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:kiln_cms, :security, :alert_failed],
      fn _event, measurements, metadata, _ ->
        send(test, {:alert_failed, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "is scheduled, fails every attempt, is never stamped failed, and is scheduled again" do
    attach_failures()
    id = insert_row!(unknown_channel())

    log = capture_log(fn -> SecurityAlerts.deliver() end)

    # Scheduled: the scheduler selects the primary key only, so it never
    # loads the channel.
    assert [job] = jobs()
    assert job.args["primary_key"] == %{"id" => id}

    # Ten attempts, each failing on the load of the row, then discarded.
    assert job.attempt == 10
    assert job.state == "discarded"
    assert length(job.errors) == 10

    # Attempts 1 to 9 log AshOban's error, the row's load failing inside the
    # worker's read; the tenth logs nothing of its own.
    assert log |> String.split("Error occurred for KilnCMS.Security.AlertDispatch") |> length() ==
             10

    assert log =~ "Error occurred on action: deliver_alert."
    assert log =~ "(CaseClauseError) no case clause matching"
    assert log =~ "cannot load"
    assert log =~ "for field :channel"

    # `:mark_failed` never ran: no report, no telemetry, no stamp.
    refute log =~ "was not delivered after its last attempt"
    refute_received {:alert_failed, _, _}

    assert [%{"id" => ^id, "failed_at" => nil, "alert_sent_at" => nil}] =
             SecurityAlerts.dispatches()

    # A discarded job does not keep the scheduler from inserting another.
    capture_log(fn -> SecurityAlerts.deliver() end)
    assert length(jobs()) == 2
  end
end
