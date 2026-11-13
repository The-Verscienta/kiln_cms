defmodule KilnCMS.Events.BackfillWorkerTest do
  @moduledoc """
  The post-deploy enqueue that removes the manual upgrade step (#766).

  What matters here is not that the job does the backfill — `BackfillTest`
  covers that — but that queueing it is **safe to do on every boot**: one job
  across a rolling deploy's replicas, at most one a day under a restart loop,
  and never an exception that stops a node from starting.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog

  alias KilnCMS.CMS
  alias KilnCMS.Events.BackfillWorker
  alias KilnCMS.Events.Recurrence

  @london "Europe/London"

  setup do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "bfw-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    name = "gig#{System.unique_integer([:positive])}"

    td =
      CMS.create_type_definition!(
        %{name: name, label: "Gig", plural_label: name, path_segment: name},
        actor: admin
      )

    CMS.create_field_definition!(
      %{type_definition_id: td.id, name: "when", label: "When", field_type: "datetime_range"},
      actor: admin
    )

    %{admin: admin, td: td, org: KilnCMS.Accounts.default_org_id()}
  end

  defp event!(ctx, days) do
    # Noon London, never the current wall time (see `KilnCMS.Events.IndexTest`).
    start = Date.utc_today() |> Date.add(days) |> NaiveDateTime.new!(~T[12:00:00])

    CMS.create_entry!(
      %{
        title: "A gig",
        slug: "ev-#{System.unique_integer([:positive])}",
        type_definition_id: ctx.td.id,
        custom_fields: %{
          "when" => %{"start" => NaiveDateTime.to_iso8601(start), "time_zone" => @london}
        }
      },
      actor: ctx.admin
    )
  end

  describe "enqueue/0" do
    test "queues one job" do
      assert :ok = BackfillWorker.enqueue()
      assert [_job] = queued()
    end

    test "a second boot does not queue a second job" do
      # A rolling deploy boots N replicas and a crash loop boots one node
      # repeatedly; `unique` is a DATABASE constraint, so both collapse to one
      # job rather than one per boot.
      assert :ok = BackfillWorker.enqueue()
      assert :ok = BackfillWorker.enqueue()
      assert :ok = BackfillWorker.enqueue()

      assert [_only_one] = queued()
    end

    test "the job carries this node's engine, on its own queue, ten minutes out" do
      # The queue is one no node of an older release polls, and the delay lets
      # the old nodes of a rolling deploy go before the pass runs (moduledoc).
      assert :ok = BackfillWorker.enqueue()
      assert [job] = queued()

      assert job.args == %{"engine" => Recurrence.engine_version()}
      assert job.queue == "occurrence_backfill"
      # And this release polls it: a queue nobody runs leaves the job waiting.
      assert Application.fetch_env!(:kiln_cms, Oban)[:queues][:occurrence_backfill] == 1
      assert job.state == "scheduled"
      assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) in 590..600
    end

    test "a completed job from before engines were recorded does not block it" do
      # The previous release's boot job (`args: %{}`) completed an hour ago.
      # With the old `[:worker]` dedup this enqueue inserted nothing, and the
      # new engine's recompute never ran.
      legacy!(%{}, "completed")

      assert :ok = BackfillWorker.enqueue()

      assert [_legacy, fresh] = Enum.sort_by(queued(), & &1.id)
      assert fresh.args == %{"engine" => Recurrence.engine_version()}
    end

    test "a completed job for this engine does block it" do
      legacy!(%{"engine" => Recurrence.engine_version()}, "completed")

      assert :ok = BackfillWorker.enqueue()

      assert [_only_the_completed_one] = queued()
    end

    test "always answers :ok, never an error tuple a caller could crash on" do
      # `Application.start/2` calls this, so its return value is on the boot
      # path: anything other than `:ok` — or a raise, which the rescue covers —
      # would take a node down over a background nicety. Asserted on both the
      # fresh insert and the deduplicated one, which are different code paths.
      assert :ok = BackfillWorker.enqueue()
      assert :ok = BackfillWorker.enqueue()
    end
  end

  describe "perform/1" do
    test "fills a row that predates the column", ctx do
      record = event!(ctx, 30) |> Ash.Seed.update!(%{next_occurrence_at: nil})

      assert :ok = perform_job(BackfillWorker, %{})

      assert CMS.get_entry!(record.id, authorize?: false).next_occurrence_at
    end

    test "a job for a newer engine snoozes and writes nothing", ctx do
      # A node of this release picking up a later release's job mid-deploy
      # would recompute with the old engine and use the new engine's run up.
      record = event!(ctx, 30) |> Ash.Seed.update!(%{next_occurrence_at: nil})

      assert {:snooze, _seconds} =
               perform_job(BackfillWorker, %{"engine" => Recurrence.engine_version() + 1})

      assert is_nil(CMS.get_entry!(record.id, authorize?: false).next_occurrence_at)
    end

    test "a job for this engine performs", ctx do
      record = event!(ctx, 30) |> Ash.Seed.update!(%{next_occurrence_at: nil})

      assert :ok = perform_job(BackfillWorker, %{"engine" => Recurrence.engine_version()})

      assert CMS.get_entry!(record.id, authorize?: false).next_occurrence_at
    end

    test "a legacy job with no engine performs rather than snoozing", ctx do
      # `nil > 1` is true in Erlang term order: without the `is_integer/1`
      # guard a job enqueued by the previous release would snooze forever.
      record = event!(ctx, 30) |> Ash.Seed.update!(%{next_occurrence_at: nil})

      assert :ok = perform_job(BackfillWorker, %{})

      assert CMS.get_entry!(record.id, authorize?: false).next_occurrence_at
    end

    test "logs how many rows changed, and names the ones that moved or left the listings",
         ctx do
      filled = event!(ctx, 30) |> Ash.Seed.update!(%{next_occurrence_at: nil})

      # A stored date that is not the event's next one: the pass moves it.
      moved =
        event!(ctx, 40)
        |> Ash.Seed.update!(%{next_occurrence_at: DateTime.add(DateTime.utc_now(), 86_400)})

      # A stored date on an event that is over: the pass writes `nil`, so the
      # event leaves the what's-on listings.
      gone =
        event!(ctx, -30)
        |> Ash.Seed.update!(%{next_occurrence_at: DateTime.add(DateTime.utc_now(), 86_400)})

      log =
        capture_log([level: :info], fn ->
          assert :ok = perform_job(BackfillWorker, %{"engine" => Recurrence.engine_version()})
        end)

      assert log =~ "[warning]"
      assert log =~ "occurrence backfill recomputed 3 record(s)"
      assert log =~ "(recurrence engine #{Recurrence.engine_version()})"
      assert log =~ "1 moved to a different date: #{moved.id};"
      assert log =~ "1 now have no upcoming date and left the what's-on listings: #{gone.id}"
      refute log =~ filled.id
    end

    test "a pass that only moves dates logs at info, not warning", ctx do
      moved =
        event!(ctx, 40)
        |> Ash.Seed.update!(%{next_occurrence_at: DateTime.add(DateTime.utc_now(), 86_400)})

      # The test env logs at `:warning` (`config/test.exs`); a per-module
      # override reaches this line without touching the global level.
      Logger.put_module_level(BackfillWorker, :info)
      on_exit(fn -> Logger.delete_module_level(BackfillWorker) end)

      log =
        capture_log([level: :info], fn ->
          assert :ok = perform_job(BackfillWorker, %{"engine" => Recurrence.engine_version()})
        end)

      assert log =~ "[info]"
      refute log =~ "[warning]"
      assert log =~ "1 moved to a different date: #{moved.id};"
      assert log =~ "0 now have no upcoming date"
    end

    test "logs nothing when nothing changed", ctx do
      event!(ctx, 30)

      log =
        capture_log([level: :info], fn ->
          assert :ok = perform_job(BackfillWorker, %{"engine" => Recurrence.engine_version()})
        end)

      refute log =~ "occurrence backfill"
    end

    test "all_types widens the pass", ctx do
      record = event!(ctx, 30)
      assert record.next_occurrence_at

      ctx.td.id
      |> CMS.field_definitions_for_definition!(authorize?: false)
      |> Enum.find(&(&1.name == "when"))
      |> CMS.destroy_field_definition!(actor: ctx.admin)

      engine = Recurrence.engine_version()

      assert :ok = perform_job(BackfillWorker, %{"engine" => engine})
      assert CMS.get_entry!(record.id, authorize?: false).next_occurrence_at

      assert :ok = perform_job(BackfillWorker, %{"engine" => engine, "all_types" => true})
      assert is_nil(CMS.get_entry!(record.id, authorize?: false).next_occurrence_at)
    end
  end

  describe "the boot gate" do
    test "is off in :test, so the suite never commits a stray oban_jobs row" do
      # Application boot happens OUTSIDE the sandbox, so a job enqueued there is
      # committed and then re-drained into whichever unrelated test drains next.
      # `test_helper.exs` deletes stray rows and warns; this config is what keeps
      # that warning meaningful.
      refute Application.get_env(:kiln_cms, :occurrence_backfill_on_boot, true)
    end
  end

  # A job row as the previous boot left it: inserted directly, because what is
  # under test is whether `enqueue/0` sees it, not how it got there.
  defp legacy!(args, state) do
    now = DateTime.utc_now()

    args
    |> Oban.Job.new(worker: "KilnCMS.Events.BackfillWorker", queue: "default")
    |> Ecto.Changeset.change(
      state: state,
      inserted_at: DateTime.add(now, -3600),
      scheduled_at: DateTime.add(now, -3600),
      completed_at: DateTime.add(now, -3500)
    )
    |> KilnCMS.Repo.insert!()
  end

  defp queued do
    Oban.Job
    |> Ecto.Query.where(worker: "KilnCMS.Events.BackfillWorker")
    |> KilnCMS.Repo.all()
  end
end
