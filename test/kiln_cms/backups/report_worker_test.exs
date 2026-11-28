defmodule KilnCMS.Backups.ReportWorkerTest do
  @moduledoc """
  The fan-out of a backup report (#2229) and its mail jobs: who gets a bell
  row, who gets an email and when they don't, what happens when the job runs
  twice or late, and the "recovered" report after a failed run is resumed and
  succeeds.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{ReportMailWorker, ReportWorker}
  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.Notification
  alias KilnCMS.Repo

  @moduletag :capture_log

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "report-#{role}-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp stamp do
    n = System.unique_integer([:positive])
    "20261127-" <> String.pad_leading(Integer.to_string(rem(n, 1_000_000)), 6, "0")
  end

  defp start!(attrs \\ %{}) do
    Backups.start_run!(
      Map.merge(%{stamp: stamp(), trigger: "manual", chain_id: Ash.UUID.generate()}, attrs),
      actor: Backups.system()
    )
  end

  defp failed!(error \\ "pg_dump exited 1"),
    do: Backups.fail_run!(start!(), %{error: error}, actor: Backups.system())

  defp succeeded!(attrs \\ %{}), do: Backups.finish_run!(start!(), attrs, actor: Backups.system())

  defp partial! do
    dests = [
      %{key: "dest:" <> Ash.UUID.generate(), kind: "s3", label: "A", status: :ok},
      %{
        key: "dest:" <> Ash.UUID.generate(),
        kind: "s3",
        label: "B",
        status: :failed,
        error: "refused"
      }
    ]

    succeeded!(%{destinations: dests, offsite_status: :partial})
  end

  # Runs the fan-out of `run`'s outcome, then marks that outcome's report
  # job completed, as Oban would (`perform_job/2` leaves the row as it was).
  defp fan_out(run) do
    result = perform_job(ReportWorker, ReportWorker.args(run))

    Repo.update_all(
      from(j in Oban.Job,
        where:
          j.worker == "KilnCMS.Backups.ReportWorker" and
            fragment("?->>'run_id'", j.args) == ^run.id and
            fragment("?->>'finished_at'", j.args) == ^DateTime.to_iso8601(run.finished_at)
      ),
      set: [state: "completed"]
    )

    result
  end

  # Every mail job, run the way Oban would: scheduled ones and snoozed ones
  # included, and the jobs they queue.
  defp drain_mail,
    do: Oban.drain_queue(queue: :mail, with_scheduled: true, with_recursion: true)

  # The mail jobs of this outcome of `run` (a resumed run has one per outcome).
  defp mail_jobs(run) do
    at = DateTime.to_iso8601(run.finished_at)

    Enum.filter(
      all_enqueued(worker: ReportMailWorker),
      &(&1.args["run_id"] == run.id and &1.args["finished_at"] == at)
    )
  end

  defp mail_job_for(run, user), do: Enum.filter(mail_jobs(run), &(&1.args["user_id"] == user.id))

  defp rows(user) do
    Repo.all(
      from(n in Notification,
        where: n.user_id == type(^user.id, :binary_id) and n.content_type == "platform_backups"
      )
    )
  end

  defp unread(user), do: Enum.filter(rows(user), &is_nil(&1.read_at))

  defp emails do
    Stream.repeatedly(fn ->
      receive do
        {:email, email} -> email
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(&(&1 != nil))
  end

  defp to(emails, user) do
    address = to_string(user.email)
    Enum.filter(emails, fn email -> Enum.any?(email.to, &(elem(&1, 1) == address)) end)
  end

  defp send_mail(run, user) do
    perform_job(ReportMailWorker, %{
      "run_id" => run.id,
      "finished_at" => DateTime.to_iso8601(run.finished_at),
      "user_id" => user.id
    })
  end

  setup do
    %{
      failures: user(:admin),
      every: user(:admin, %{notify_on_backup: :every_run}),
      off: user(:admin, %{notify_on_backup: :off}),
      editor: user(:editor, %{notify_on_backup: :every_run})
    }
  end

  describe "a failed run" do
    test "a bell row for every platform admin, mail for the ones who want it", ctx do
      run = failed!()
      assert :ok = fan_out(run)

      for admin <- [ctx.failures, ctx.every, ctx.off] do
        assert [row] = rows(admin)
        assert row.event == :backup_failed
        assert row.org_id == Accounts.default_org_id()
        assert row.content_id == Accounts.default_org_id()
        assert row.details["run_id"] == run.id
        assert row.excerpt =~ "pg_dump exited 1"
      end

      assert [_] = mail_job_for(run, ctx.failures)
      assert [_] = mail_job_for(run, ctx.every)
      # `:off` mutes the email only.
      assert mail_job_for(run, ctx.off) == []
    end

    test "a non-admin set to every run gets nothing", ctx do
      run = failed!()
      fan_out(run)
      assert rows(ctx.editor) == []
      assert mail_job_for(run, ctx.editor) == []
    end

    test "the mail job carries ids only", ctx do
      run = failed!()
      fan_out(run)
      assert [job] = mail_job_for(run, ctx.failures)
      assert job.args |> Map.keys() |> Enum.sort() == ["finished_at", "run_id", "user_id"]
    end

    test "the email says what failed, on the instance relay", ctx do
      run = failed!()
      fan_out(run)
      emails()

      assert :ok = send_mail(run, ctx.failures)
      assert [email] = to(emails(), ctx.failures)
      assert email.subject =~ "Backup failed on"
      assert email.text_body =~ "pg_dump exited 1"
      assert email.text_body =~ "set to failures only"
    end
  end

  describe ":failures" do
    test "gets no mail for a succeeded, skipped or canceled run", ctx do
      admin = user(:admin)
      succeeded = succeeded!()

      skipped =
        Backups.skip_run!(%{stamp: stamp(), trigger: "manual", error: "no pg_dump"},
          actor: Backups.system()
        )

      canceled = Backups.cancel_run!(start!(%{chain_id: nil}), actor: admin)

      for run <- [succeeded, skipped, canceled] do
        fan_out(run)
        assert mail_job_for(run, ctx.failures) == []
        assert [_] = mail_job_for(run, ctx.every)
        assert mail_job_for(run, ctx.off) == []
      end

      # And no bell row for any of them.
      assert rows(ctx.failures) == []
    end

    test "gets mail for a partly off-site run, with its own bell row", ctx do
      run = partial!()
      fan_out(run)

      assert [_] = mail_job_for(run, ctx.failures)
      assert [row] = rows(ctx.off)
      assert row.event == :backup_partly_offsite
      assert row.excerpt =~ "reached 1 of 2 off-site destinations"
    end

    test "a stored preference a newer release wrote counts as :failures", ctx do
      {1, _} =
        Repo.update_all(from(u in "users", where: u.id == type(^ctx.failures.id, :binary_id)),
          set: [notify_on_backup: "weekly_digest"]
        )

      reloaded = Accounts.get_user!(ctx.failures.id, authorize?: false)
      assert %KilnCMS.Types.UnknownAtom{value: "weekly_digest"} = reloaded.notify_on_backup

      failed = failed!()
      succeeded = succeeded!()
      fan_out(failed)
      fan_out(succeeded)

      assert [_] = mail_job_for(failed, ctx.failures)
      assert mail_job_for(succeeded, ctx.failures) == []

      emails()
      assert :ok = send_mail(failed, reloaded)
      assert [_] = to(emails(), ctx.failures)
    end
  end

  describe "idempotency" do
    test "a fan-out run twice queues one mail job per admin and leaves one bell row", ctx do
      run = failed!()
      fan_out(run)
      fan_out(run)

      assert [_] = mail_job_for(run, ctx.failures)
      assert [_] = mail_job_for(run, ctx.every)
      assert [_] = rows(ctx.failures)
    end

    test "a second failure while the first is unread refreshes the row to the newest run", ctx do
      first = failed!("first failure")
      fan_out(first)
      second = failed!("second failure")
      fan_out(second)

      assert [row] = rows(ctx.failures)
      assert row.details["run_id"] == second.id
      assert row.excerpt =~ "second failure"
      assert is_nil(row.read_at)
    end

    test "once the row is read, the next failure is a new row", ctx do
      fan_out(failed!())
      [row] = rows(ctx.failures)

      Notifications.mark_notification_read!(row,
        actor: ctx.failures,
        tenant: Accounts.default_org_id()
      )

      fan_out(failed!())
      assert [_, _] = rows(ctx.failures)
      assert [_] = unread(ctx.failures)
    end

    test "a job whose finished_at is not the run's any more sends nothing", ctx do
      run = failed!()

      assert :ok =
               perform_job(ReportWorker, %{
                 "run_id" => run.id,
                 "finished_at" => DateTime.to_iso8601(DateTime.add(run.finished_at, -5, :second))
               })

      assert rows(ctx.failures) == []
      assert mail_jobs(run) == []

      fan_out(run)
      emails()

      assert :ok =
               perform_job(ReportMailWorker, %{
                 "run_id" => run.id,
                 "finished_at" => "2020-01-01T00:00:00.000000Z",
                 "user_id" => ctx.failures.id
               })

      assert to(emails(), ctx.failures) == []
    end

    test "a run that is gone, or still running, sends nothing" do
      assert :ok =
               perform_job(ReportWorker, %{"run_id" => Ash.UUID.generate(), "finished_at" => nil})

      running = start!()
      assert :ok = perform_job(ReportWorker, %{"run_id" => running.id, "finished_at" => nil})

      assert Enum.filter(
               all_enqueued(worker: ReportMailWorker),
               &(&1.args["run_id"] == running.id)
             ) == []
    end

    test "a refused read fails the job, which retries: never taken for gone", ctx do
      run = failed!()

      # Not a platform admin, whom the Run read policy admits.
      assert {:error, %Ash.Error.Forbidden{}} =
               Backups.with_actor(ctx.editor, fn -> fan_out(run) end)

      assert rows(ctx.failures) == []
      assert mail_jobs(run) == []
    end
  end

  describe "a failed run resumed and then succeeded" do
    defp recover!(failed) do
      resumed =
        Backups.resume_run!(failed, %{chain_id: Ash.UUID.generate()}, actor: Backups.system())

      Backups.finish_run!(resumed, %{}, actor: Backups.system())
    end

    test "says it recovered to who got the failure, and reads the failure's row", ctx do
      failed = failed!()
      fan_out(failed)
      assert [_] = unread(ctx.failures)

      recovered = recover!(failed)
      assert recovered.last_failed_at == failed.finished_at
      fan_out(recovered)

      for admin <- [ctx.failures, ctx.every, ctx.off] do
        assert unread(admin) == []
      end

      assert [_] = mail_job_for(recovered, ctx.failures)
      assert [_] = mail_job_for(recovered, ctx.every)
      assert mail_job_for(recovered, ctx.off) == []

      emails()
      assert :ok = send_mail(recovered, ctx.failures)
      assert [email] = to(emails(), ctx.failures)
      assert email.subject =~ "Backup recovered on"
    end

    test "is not sent to an admin who chose Off after the failure", ctx do
      failed = failed!()
      fan_out(failed)
      assert [_] = mail_job_for(failed, ctx.failures)

      muted =
        Accounts.update_notification_prefs!(ctx.failures, %{notify_on_backup: :off},
          actor: ctx.failures
        )

      recovered = recover!(failed)
      fan_out(recovered)
      assert mail_job_for(recovered, muted) == []

      emails()
      assert :ok = send_mail(recovered, muted)
      assert to(emails(), muted) == []
    end

    test "goes only to admins a failure report was queued for", ctx do
      failed = failed!()
      fan_out(failed)

      # Joined after the failure, with the same preference: not told.
      late = user(:admin)

      recovered = recover!(failed)
      fan_out(recovered)

      assert [_] = mail_job_for(recovered, ctx.failures)
      assert mail_job_for(recovered, late) == []
    end

    test "waits for the failure's fan-out when that has not run yet", ctx do
      failed = failed!()
      recovered = recover!(failed)

      assert {:snooze, 60} = perform_job(ReportWorker, ReportWorker.args(recovered))
      assert mail_job_for(recovered, ctx.failures) == []
    end

    test "leaves a row refreshed to another run's failure unread", ctx do
      failed = failed!()
      fan_out(failed)
      other = failed!("another failure")
      fan_out(other)

      fan_out(recover!(failed))

      assert [row] = unread(ctx.failures)
      assert row.details["run_id"] == other.id
    end

    test "a plain success sends :failures nothing", ctx do
      run = succeeded!()
      fan_out(run)
      assert mail_job_for(run, ctx.failures) == []
    end
  end

  describe "a failure resumed before its report ran (within the minute)" do
    test "then succeeded: the failure is reported, then the recovery, to the same admins",
         ctx do
      failed = failed!()

      resumed =
        Backups.resume_run!(failed, %{chain_id: Ash.UUID.generate()}, actor: Backups.system())

      Backups.finish_run!(resumed, %{}, actor: Backups.system())
      emails()

      drain_mail()
      sent = emails()

      assert [failure, recovery] =
               ctx.failures |> then(&to(sent, &1)) |> Enum.sort_by(&(&1.subject =~ "recovered"))

      assert failure.subject =~ "Backup failed on"
      assert failure.text_body =~ "It has been resumed since"
      assert recovery.subject =~ "Backup recovered on"

      assert [_, _] = to(sent, ctx.every)
      assert to(sent, ctx.off) == []
      assert unread(ctx.failures) == []
    end

    test "then canceled: the failure is reported, and no recovery", ctx do
      failed = failed!()

      resumed =
        Backups.resume_run!(failed, %{chain_id: Ash.UUID.generate()}, actor: Backups.system())

      Backups.cancel_run!(resumed, actor: user(:admin))
      emails()

      drain_mail()
      sent = emails()

      assert [failure] = to(sent, ctx.failures)
      assert failure.subject =~ "Backup failed on"
      refute Enum.any?(sent, &(&1.subject =~ "recovered"))
      # Every run hears the failure and the Cancel.
      assert [_, _] = to(sent, ctx.every)
      assert [row] = unread(ctx.failures)
      assert row.event == :backup_failed
    end

    test "still running: the failure is reported", ctx do
      failed = failed!()
      Backups.resume_run!(failed, %{chain_id: Ash.UUID.generate()}, actor: Backups.system())
      emails()

      drain_mail()
      sent = emails()

      assert [failure] = to(sent, ctx.failures)
      assert failure.subject =~ "Backup failed on"
      assert failure.text_body =~ "It has been resumed since"
      assert [_row] = unread(ctx.failures)
    end
  end

  describe "an import pass that records many cron runs" do
    defp import!(attrs) do
      Backups.import_run!(
        Map.merge(
          %{stamp: stamp(), trigger: "cron", status: :succeeded, components: [:db]},
          attrs
        ),
        actor: Backups.system()
      )
    end

    defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

    test "mails about its newest succeeded run only; each failure still", ctx do
      for n <- 1..10 do
        import!(%{started_at: ago(3_000 - n * 100), finished_at: ago(2_990 - n * 100)})
      end

      import!(%{
        status: :failed,
        error: "pg_dump exited 1",
        started_at: ago(5_000),
        finished_at: ago(4_990)
      })

      emails()

      drain_mail()
      sent = emails()

      every = to(sent, ctx.every)
      assert length(every) == 2
      assert Enum.count(every, &(&1.subject =~ "Backup report: succeeded")) == 1
      assert Enum.count(every, &(&1.subject =~ "Backup failed")) == 1
      assert [_failure_only] = to(sent, ctx.failures)
    end
  end

  describe "a re-send" do
    test "leaves the partly off-site row as it is, and reports nothing new", ctx do
      run = partial!()
      fan_out(run)
      assert [row] = unread(ctx.failures)

      Backups.record_run_resend!(run, %{offsite_status: :complete}, actor: Backups.system())

      assert [^row] = unread(ctx.failures)

      assert [_finish_only] =
               Repo.all(
                 from(j in Oban.Job,
                   where:
                     j.worker == "KilnCMS.Backups.ReportWorker" and
                       fragment("?->>'run_id'", j.args) == ^run.id
                 )
               )
    end
  end

  describe "an interrupted run" do
    test "the report is read when it runs, after the interrupted record lands", ctx do
      run = failed!("Interrupted: the job was killed or the node stopped")

      assert [%{state: "scheduled"}] =
               all_enqueued(worker: ReportWorker, args: %{"run_id" => run.id})

      Backups.record_run_interrupted!(
        run,
        %{
          log: [%{level: :error, step: "dump", message: "pg_dump: the late line"}],
          failed_at: run.updated_at
        },
        actor: Backups.system()
      )

      fan_out(run)
      emails()
      assert :ok = send_mail(run, ctx.failures)
      assert [email] = to(emails(), ctx.failures)
      assert email.text_body =~ "pg_dump: the late line"
    end
  end

  describe "the mail job, when it runs" do
    setup ctx do
      run = failed!()
      fan_out(run)
      emails()
      Map.put(ctx, :run, run)
    end

    test "skips an admin demoted after the fan-out", %{run: run} = ctx do
      Ash.Seed.update!(ctx.failures, %{role: :editor})
      assert :ok = send_mail(run, ctx.failures)
      assert to(emails(), ctx.failures) == []
    end

    test "skips an admin whose temporary admin grant expired", %{run: run} do
      granted =
        user(:editor, %{
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert :ok = send_mail(run, granted)
      assert to(emails(), granted) == []
    end

    test "skips an admin who muted it since", %{run: run} = ctx do
      Accounts.update_notification_prefs!(ctx.failures, %{notify_on_backup: :off},
        actor: ctx.failures
      )

      assert :ok = send_mail(run, ctx.failures)
      assert to(emails(), ctx.failures) == []
    end

    test "skips an erased account", %{run: run} = ctx do
      address = to_string(ctx.failures.email)
      Accounts.anonymize_user!(ctx.failures, actor: ctx.every)
      assert :ok = send_mail(run, ctx.failures)
      assert Enum.filter(emails(), fn e -> Enum.any?(e.to, &(elem(&1, 1) == address)) end) == []
    end

    test "skips a suppressed address", %{run: run} = ctx do
      KilnCMS.Mail.suppress_recipient!(%{email: to_string(ctx.failures.email)}, authorize?: false)
      assert :ok = send_mail(run, ctx.failures)
      assert to(emails(), ctx.failures) == []
    end

    test "skips a non-admin, whatever it asked for", %{run: run} = ctx do
      assert :ok = send_mail(run, ctx.editor)
      assert to(emails(), ctx.editor) == []
    end
  end
end
