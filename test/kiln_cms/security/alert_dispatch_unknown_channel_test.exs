defmodule KilnCMS.Security.AlertDispatchUnknownChannelTest do
  @moduledoc """
  A dispatch row whose `channel` this release does not know (#3496): one a
  later release wrote, met after a rollback or on an old node in a rolling
  deploy, as v1.13.0 meets a `platform_notice` row.

  The channel is a string built at run time, so it is no atom this VM knows.
  v1.13.0 (plain `:atom`, no channel list in its triggers) schedules such a
  row and fails to load it on every attempt: nine AshOban error logs, a
  discarded job, no `failed_at`, and the scheduler inserts another job a
  minute later. This release never schedules it, cancels a job that names it
  anyway, and a delivery run straight on it sends nothing, stamps nothing and does not raise.

  It also pins what this release writes against v1.13.0's two trigger
  predicates, copied from `git show v1.13.0:lib/kiln_cms/security/alert_dispatch.ex`
  as SQL: a delivered platform notice must never match v1.13.0's summary
  trigger.

  `async: false`: the triggers are drained in this process, and alerts are
  turned on (`KilnCMS.Test.SecurityAlerts.enable/0`, an
  `Application.put_env`).
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Accounts
  alias KilnCMS.Notifications.Notification
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.Security.AlertDispatch
  alias KilnCMS.Security.AlertGate
  alias KilnCMS.Security.Changes.DeliverAlert
  alias KilnCMS.Test.SecurityAlerts
  alias KilnCMS.Types.KnownAtom
  alias KilnCMS.Types.UnknownAtom

  @alert_worker KilnCMS.Security.AlertDispatch.AshOban.Worker.DeliverAlert
  @alert_scheduler KilnCMS.Security.AlertDispatch.AshOban.Scheduler.DeliverAlert
  @summary_worker KilnCMS.Security.AlertDispatch.AshOban.Worker.DeliverSummary
  @summary_scheduler KilnCMS.Security.AlertDispatch.AshOban.Scheduler.DeliverSummary

  # v1.13.0's `:deliver_alert` and `:deliver_summary` `where`s, as SQL. Not
  # derived from this release's code: they are what an old node runs.
  @v1_13_deliver_alert """
  alert_sent_at IS NULL AND failed_at IS NULL
    AND inserted_at > (now() AT TIME ZONE 'UTC') - interval '1 day'
  """

  @v1_13_deliver_summary """
  channel != 'notice' AND alert_sent_at IS NOT NULL AND summary_sent_at IS NULL
    AND failed_at IS NULL
    AND window_ends_at < (now() AT TIME ZONE 'UTC') - interval '1 minute'
    AND window_ends_at > (now() AT TIME ZONE 'UTC') - interval '1 day'
  """

  setup do
    SecurityAlerts.enable()
    :ok
  end

  defp unknown_channel do
    channel = "zz_unknown_channel_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(channel) end
    channel
  end

  # A pending row on `channel`, shaped as the notice gate writes one.
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

  defp jobs(worker) do
    name = inspect(worker)
    Oban.Job |> Repo.all() |> Enum.filter(&(&1.worker == name))
  end

  defp scheduled_ids(worker),
    do: worker |> jobs() |> MapSet.new(& &1.args["primary_key"]["id"])

  # The trigger's real scheduler, once, without running what it enqueues.
  defp run_scheduler(scheduler), do: Oban.Testing.perform_job(scheduler, %{}, repo: Repo)

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

  defp matches?(predicate, id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM security_alert_dispatches " <>
          "WHERE id = $1::text::uuid AND (#{predicate})",
        [id]
      )

    count == 1
  end

  defp channels, do: Ash.Resource.Info.attribute(AlertDispatch, :channel).constraints[:one_of]

  describe "the type" do
    test "plain :atom, as v1.13.0 has, cannot load the channel; KnownAtom can" do
      channel = unknown_channel()
      one_of = [:site, :platform, :notice]

      # What fails every v1.13.0 read of the row.
      assert Ash.Type.cast_stored(Ash.Type.Atom, channel, one_of: one_of) == :error

      assert Ash.Type.cast_stored(KnownAtom, channel, one_of: one_of) ==
               {:ok, %UnknownAtom{value: channel}}
    end
  end

  describe "a row with a channel this release does not know" do
    test "is never scheduled, and nothing is logged or stamped" do
      attach_failures()
      id = insert_row!(unknown_channel())

      log = capture_log(fn -> SecurityAlerts.deliver() end)

      assert jobs(@alert_worker) == []
      assert jobs(@summary_worker) == []
      refute log =~ "Error occurred for KilnCMS.Security.AlertDispatch"
      refute_received {:alert_failed, _, _}

      assert [%{"id" => ^id, "alert_sent_at" => nil, "failed_at" => nil}] =
               SecurityAlerts.dispatches()
    end

    test "a job that names it anyway is cancelled, quietly, on its first attempt" do
      attach_failures()
      id = insert_row!(unknown_channel())

      Oban.insert!(@alert_worker.new(%{primary_key: %{id: id}}))

      log = capture_log(fn -> Oban.drain_queue(queue: :default, with_recursion: true) end)

      assert [%{state: "cancelled", attempt: 1}] = jobs(@alert_worker)
      refute log =~ "Error occurred"
      refute_received {:alert_failed, _, _}
      assert [%{"alert_sent_at" => nil, "failed_at" => nil}] = SecurityAlerts.dispatches()
    end

    test "a delivery run straight on it sends nothing, stamps nothing, and does not raise" do
      channel = unknown_channel()
      id = insert_row!(channel)

      # The record as the worker's read loads it: the channel as an UnknownAtom.
      dispatch =
        struct(AlertDispatch, %{
          id: id,
          kind: "alerts_silenced",
          org_id: Accounts.default_org_id(),
          channel: %UnknownAtom{value: channel}
        })

      log =
        capture_log(fn ->
          # authorize?: false — the action is the triggers' alone (AshOban's bypass).
          assert {:error, error} = Security.deliver_alert_dispatch(dispatch, authorize?: false)
          assert Exception.message(error) =~ "is not one this release delivers"
        end)

      assert log =~ "has a channel this release does not know"
      assert Repo.all(Notification) == []

      # Left unstamped: the release that wrote it still owns its delivery.
      assert [%{"alert_sent_at" => nil, "summary_sent_at" => nil, "failed_at" => nil}] =
               SecurityAlerts.dispatches()

      for phase <- [:alert, :summary] do
        assert capture_log(fn ->
                 assert %{data: nil, bell: [], mail: [], endpoints: []} =
                          DeliverAlert.build_plan(dispatch, phase)
               end) =~ "its #{phase} is not sent here"
      end
    end
  end

  describe "a row its trigger no longer applies to" do
    test "has its job cancelled by AshOban's worker, and nothing is sent" do
      id = insert_row!("site")
      Repo.query!("UPDATE security_alert_dispatches SET alert_sent_at = now()")

      Oban.insert!(@alert_worker.new(%{primary_key: %{id: id}}))
      log = capture_log(fn -> Oban.drain_queue(queue: :default, with_recursion: true) end)

      assert [%{state: "cancelled", attempt: 1}] = jobs(@alert_worker)
      refute log =~ "Error occurred"
      assert Repo.all(Notification) == []
    end
  end

  describe "the triggers' channel lists" do
    test "the alert trigger schedules a pending row on every channel the attribute allows" do
      assert :platform_notice in channels()

      ids = Map.new(channels(), &{&1, insert_row!(Atom.to_string(&1))})
      unknown = insert_row!(unknown_channel())

      run_scheduler(@alert_scheduler)
      scheduled = scheduled_ids(@alert_worker)

      for {channel, id} <- ids do
        assert id in scheduled, "a pending #{channel} row was not scheduled"
      end

      refute unknown in scheduled
    end

    test "the summary trigger schedules a site or platform row only" do
      ids = Map.new(channels(), &{&1, insert_row!(Atom.to_string(&1))})
      unknown = insert_row!(unknown_channel())

      # Delivered, window closed, no summary yet: each is due but for its channel.
      Repo.query!("""
      UPDATE security_alert_dispatches
      SET alert_sent_at = now(),
          window_ends_at = (now() AT TIME ZONE 'UTC') - interval '2 minutes'
      """)

      run_scheduler(@summary_scheduler)

      assert scheduled_ids(@summary_worker) == MapSet.new([ids.site, ids.platform])
      refute unknown in scheduled_ids(@summary_worker)
    end
  end

  describe "v1.13.0's trigger predicates, against the rows this release writes" do
    setup do
      platform =
        Ash.Seed.seed!(Accounts.User, %{
          email: "unknown-channel-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })

      %{platform: platform}
    end

    test "a delivered platform notice never matches v1.13.0's summary trigger", ctx do
      {:ok, id} =
        Repo.transaction(fn ->
          AlertGate.insert_platform_notice!(%{
            change: "platform_kind_disabled",
            kinds: ["api_key_rate_limited"],
            actor_id: ctx.platform.id
          })
        end)

      # Pending, it matches v1.13.0's alert trigger: an old node schedules it
      # and fails to load it. Nothing this release writes can change that.
      assert matches?(@v1_13_deliver_alert, id)

      SecurityAlerts.deliver()
      SecurityAlerts.close_window(id)

      assert [%{"alert_sent_at" => %NaiveDateTime{}, "summary_sent_at" => %NaiveDateTime{}}] =
               SecurityAlerts.dispatches()

      refute matches?(@v1_13_deliver_alert, id)
      refute matches?(@v1_13_deliver_summary, id)
    end

    test "a site notice stays excluded from v1.13.0's summary trigger by its channel", ctx do
      org = KilnCMS.OrgFixtures.org("unknown-channel-site")

      {:ok, id} =
        Repo.transaction(fn ->
          AlertGate.insert_notice!(org.id, %{
            change: "kind_disabled",
            kinds: ["lockout"],
            actor_id: ctx.platform.id
          })
        end)

      SecurityAlerts.deliver()
      SecurityAlerts.close_window(id)

      assert [%{"alert_sent_at" => %NaiveDateTime{}, "summary_sent_at" => nil}] =
               SecurityAlerts.dispatches()

      refute matches?(@v1_13_deliver_summary, id)
    end
  end
end
