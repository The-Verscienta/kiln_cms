defmodule KilnCMS.Backups.ReportOutboxTest do
  @moduledoc """
  A backup run's report is enqueued in the write that records its outcome
  (#2229, ADR 0094): one `ReportWorker` job per committed terminal write,
  none for a write that rolls back, loses its race, or leaves the status as
  it was. Imported (cron) runs are reported too, unless they are old.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Importer, ReportWorker}
  alias KilnCMS.Backups.Run.Changes.AfterOutcome
  alias KilnCMS.Repo
  alias KilnCMS.Test.BackupSchedules

  @moduletag :capture_log

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

  defp report_jobs(run_id) do
    Repo.all(
      from(j in Oban.Job,
        where:
          j.worker == "KilnCMS.Backups.ReportWorker" and
            fragment("?->>'run_id'", j.args) == ^run_id
      )
    )
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp set_run!(run, fields) do
    {1, _} =
      Repo.update_all(from(r in "backup_runs", where: r.id == type(^run.id, :binary_id)),
        set: fields
      )

    Backups.get_run!(run.id, actor: Backups.system())
  end

  describe "an in-app run" do
    test "a finish enqueues one report job, available now, carrying ids only" do
      run = start!()
      assert report_jobs(run.id) == []

      run = Backups.finish_run!(run, %{}, actor: Backups.system())

      assert [job] = report_jobs(run.id)
      assert job.state == "available"
      assert job.queue == "mail"

      assert job.args == %{
               "run_id" => run.id,
               "finished_at" => DateTime.to_iso8601(run.finished_at)
             }

      assert Map.keys(job.args) |> Enum.sort() == ["finished_at", "run_id"]
      assert run.last_failed_at == nil
    end

    test "a fail enqueues one, a minute out, and remembers the failure" do
      run = Backups.fail_run!(start!(), %{error: "tar exited 2"}, actor: Backups.system())

      assert [job] = report_jobs(run.id)
      assert job.state == "scheduled"
      assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) in 50..61
      assert run.last_failed_at == run.finished_at
    end

    test "a skipped attempt enqueues one" do
      run =
        Backups.skip_run!(%{stamp: stamp(), trigger: "manual", error: "no pg_dump"},
          actor: Backups.system()
        )

      assert [%{state: "available"}] = report_jobs(run.id)
    end

    test "a progress write enqueues nothing" do
      run = start!()

      Backups.record_run_progress!(run, %{log: [%{step: "dump", message: "ok"}]},
        actor: Backups.system()
      )

      assert report_jobs(run.id) == []
    end

    test "the losing terminal writer enqueues nothing" do
      run = start!()
      Backups.finish_run!(run, %{}, actor: Backups.system())

      # The stale struct still says `running`: its write matches no row.
      assert {:error, %Ash.Error.Invalid{}} =
               Backups.fail_run(run, %{error: "late"}, actor: Backups.system())

      assert [_one] = report_jobs(run.id)
    end

    test "the stale-run sweep's fail enqueues one" do
      run = start!()
      set_run!(run, started_at: ago(10 * 3600), updated_at: ago(10 * 3600))

      assert Backups.reconcile_stale_runs() == 1
      assert [_one] = report_jobs(run.id)
    end

    test "a resume keeps the remembered failure, and its finish enqueues a second report" do
      run = Backups.fail_run!(start!(), %{error: "boom"}, actor: Backups.system())
      failed_at = run.last_failed_at

      resumed =
        Backups.resume_run!(run, %{chain_id: Ash.UUID.generate()}, actor: Backups.system())

      assert resumed.last_failed_at == failed_at
      assert [_failure] = report_jobs(run.id)

      finished = Backups.finish_run!(resumed, %{}, actor: Backups.system())
      assert finished.last_failed_at == failed_at

      assert [_, _] = jobs = report_jobs(run.id)

      assert Enum.map(jobs, & &1.args["finished_at"]) |> Enum.sort() ==
               Enum.sort([
                 DateTime.to_iso8601(run.finished_at),
                 DateTime.to_iso8601(finished.finished_at)
               ])
    end

    test "a re-send's record enqueues nothing" do
      run = Backups.finish_run!(start!(), %{}, actor: Backups.system())
      Backups.record_run_resend!(run, %{offsite_status: :complete}, actor: Backups.system())
      assert [_finish_only] = report_jobs(run.id)
    end
  end

  describe "a Cancel" do
    setup do
      %{admin: BackupSchedules.platform_admin()}
    end

    test "that commits enqueues one", %{admin: admin} do
      run = start!(%{chain_id: nil})
      assert {:ok, canceled} = Backups.cancel_run(run, actor: admin)
      assert canceled.status == :canceled
      assert [_one] = report_jobs(run.id)
    end

    test "rolled back inside the lock's transaction enqueues no job", %{admin: admin} do
      run = start!(%{chain_id: nil})

      assert {:error, :rolled_back} =
               Repo.transaction(fn ->
                 assert {:ok, _canceled} = Backups.cancel_run(run, actor: admin)
                 assert [_inside] = report_jobs(run.id)
                 Repo.rollback(:rolled_back)
               end)

      assert report_jobs(run.id) == []
      assert Backups.get_run!(run.id, actor: Backups.system()).status == :running
    end
  end

  describe "a refused resume (critic fix 1)" do
    test "on a stale running run fails it and enqueues one" do
      run = start!()
      stale = set_run!(run, started_at: ago(10 * 3600), updated_at: ago(10 * 3600))

      noted =
        Backups.note_run_resume_refused!(stale, "no server has its files",
          actor: Backups.system()
        )

      assert noted.status == :failed
      assert noted.last_failed_at == noted.finished_at
      assert [_one] = report_jobs(run.id)
    end

    test "on a failed run keeps it failed and enqueues nothing more" do
      run = Backups.fail_run!(start!(), %{error: "boom"}, actor: Backups.system())
      assert [_failure] = report_jobs(run.id)

      noted =
        Backups.note_run_resume_refused!(run, "no server has its files", actor: Backups.system())

      assert noted.status == :failed
      assert noted.last_failed_at == run.last_failed_at
      assert [_still_one] = report_jobs(run.id)
    end
  end

  describe "an imported (cron) run" do
    defp import!(attrs) do
      Backups.import_run!(
        Map.merge(
          %{
            stamp: stamp(),
            trigger: "cron",
            status: :succeeded,
            components: [:db],
            started_at: ago(600),
            finished_at: ago(300)
          },
          attrs
        ),
        actor: Backups.system()
      )
    end

    test "a recent one is reported" do
      run = import!(%{})
      assert run.origin == :imported
      assert [job] = report_jobs(run.id)
      assert job.args["finished_at"] == DateTime.to_iso8601(run.finished_at)
    end

    test "a failed one remembers the failure" do
      run = import!(%{status: :failed, error: "pg_dump exited 1"})
      assert run.last_failed_at == run.finished_at
      assert [%{state: "scheduled"}] = report_jobs(run.id)
    end

    test "one older than the window is imported without a report" do
      old = AfterOutcome.import_window_s() + 3600
      run = import!(%{started_at: ago(old + 60), finished_at: ago(old)})
      assert report_jobs(run.id) == []
    end

    test "an import that hits an existing stamp enqueues nothing" do
      app = start!()

      assert {:ok, existing} =
               Backups.import_run(
                 %{stamp: app.stamp, status: :failed, error: "x", started_at: ago(60)},
                 actor: Backups.system()
               )

      assert existing.id == app.id
      assert existing.origin == :app
      assert report_jobs(app.id) == []
    end

    test "a re-evaluated Interrupted import enqueues a second report" do
      run =
        import!(%{
          status: :failed,
          error: Importer.interrupted_message(),
          finished_at: ago(200)
        })

      assert [_failure] = report_jobs(run.id)

      reevaluated =
        Backups.reevaluate_interrupted_run!(
          run,
          %{status: :succeeded, error: nil, finished_at: ago(100), components: [:db]},
          actor: Backups.system()
        )

      assert reevaluated.status == :succeeded
      assert [_, _] = report_jobs(run.id)
    end
  end

  describe "a re-evaluated Interrupted import that is still failed (review 3)" do
    test "is a new outcome: its failure is remembered and reported" do
      run =
        Backups.import_run!(
          %{
            stamp: stamp(),
            trigger: "cron",
            status: :failed,
            components: [:db],
            error: Importer.interrupted_message(),
            started_at: ago(600),
            finished_at: ago(300)
          },
          actor: Backups.system()
        )

      assert [_interrupted] = report_jobs(run.id)

      reevaluated =
        Backups.reevaluate_interrupted_run!(
          run,
          %{status: :failed, error: "empty artifact", finished_at: ago(100), components: [:db]},
          actor: Backups.system()
        )

      assert reevaluated.status == :failed
      assert reevaluated.last_failed_at == reevaluated.finished_at
      assert [_, _] = jobs = report_jobs(run.id)

      assert DateTime.to_iso8601(reevaluated.finished_at) in Enum.map(
               jobs,
               & &1.args["finished_at"]
             )
    end
  end

  test "the job's args are exactly the id keys" do
    run = Backups.finish_run!(start!(), %{}, actor: Backups.system())
    assert ReportWorker.args(run) |> Map.keys() |> Enum.sort() == ["finished_at", "run_id"]
  end
end
