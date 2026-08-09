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

  alias KilnCMS.CMS
  alias KilnCMS.Events.BackfillWorker

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
    start =
      DateTime.utc_now()
      |> DateTime.add(days * 86_400, :second)
      |> DateTime.shift_zone!(@london)
      |> DateTime.to_naive()

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

    test "all_types widens the pass", ctx do
      record = event!(ctx, 30)
      assert record.next_occurrence_at

      ctx.td.id
      |> CMS.field_definitions_for_definition!(authorize?: false)
      |> Enum.find(&(&1.name == "when"))
      |> CMS.destroy_field_definition!(actor: ctx.admin)

      assert :ok = perform_job(BackfillWorker, %{})
      assert CMS.get_entry!(record.id, authorize?: false).next_occurrence_at

      assert :ok = perform_job(BackfillWorker, %{"all_types" => true})
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

  defp queued do
    Oban.Job
    |> Ecto.Query.where(worker: "KilnCMS.Events.BackfillWorker")
    |> KilnCMS.Repo.all()
  end
end
