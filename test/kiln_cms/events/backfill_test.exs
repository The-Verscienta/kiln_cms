defmodule KilnCMS.Events.BackfillTest do
  @moduledoc """
  The one-off pass that fills `next_occurrence_at` for content that predates
  #766.

  The test that matters most is not "it fills the column" — it is that a
  **second** run writes nothing. A backfill touches the archive, and one that
  rewrites every row bumps `updated_at` across the whole site (reordering the
  feeds and the sitemap) and drops the sitemap/llms/feed caches once per row.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Events.Backfill
  alias KilnCMS.Events.Index

  @london "Europe/London"

  setup do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "bfl-#{System.unique_integer([:positive])}@example.com",
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

    for {field, type} <- [{"when", "datetime_range"}, {"repeats", "recurrence"}] do
      CMS.create_field_definition!(
        %{type_definition_id: td.id, name: field, label: field, field_type: type},
        actor: admin
      )
    end

    %{admin: admin, td: td, type: name, org: KilnCMS.Accounts.default_org_id()}
  end

  defp schedule(days) do
    start =
      DateTime.utc_now()
      |> DateTime.add(days * 86_400, :second)
      |> DateTime.shift_zone!(@london)
      |> DateTime.to_naive()

    %{"start" => NaiveDateTime.to_iso8601(start), "time_zone" => @london}
  end

  defp event!(ctx, fields) do
    CMS.create_entry!(
      %{
        title: "A gig",
        slug: "ev-#{System.unique_integer([:positive])}",
        type_definition_id: ctx.td.id,
        custom_fields: fields
      },
      actor: ctx.admin
    )
  end

  # The state an upgraded site is in: rows that existed before the column did.
  # Written straight to the row, because that is exactly what the migration
  # leaves behind — a NULL nothing has computed yet.
  defp unbackfilled!(record), do: Ash.Seed.update!(record, %{next_occurrence_at: nil})

  defp reload(record), do: CMS.get_entry!(record.id, authorize?: false)

  describe "filling the gap the migration leaves" do
    test "a NULL row with an upcoming event gets its sort key", ctx do
      record = ctx |> event!(%{"when" => schedule(30)}) |> unbackfilled!()
      assert is_nil(reload(record).next_occurrence_at)

      assert %{written: written} = Backfill.run_org(ctx.org)
      assert written >= 1

      filled = reload(record).next_occurrence_at
      assert filled
      assert DateTime.compare(filled, Index.anchor()) != :lt
    end

    test "the sweep alone would NOT have filled it", ctx do
      # The whole reason this module exists: the sweep visits rows whose value
      # has passed, and a NULL has passed nothing. If this ever starts failing,
      # the backfill is redundant — but so is one of the sweep's guarantees.
      record = ctx |> event!(%{"when" => schedule(30)}) |> unbackfilled!()

      KilnCMS.Events.Sweep.run_org(ctx.org)

      assert is_nil(reload(record).next_occurrence_at)
    end

    test "a recurring series whose start is in the past is filled with its next date", ctx do
      record =
        ctx
        |> event!(%{"when" => schedule(-365), "repeats" => %{"rrule" => "FREQ=WEEKLY"}})
        |> unbackfilled!()

      Backfill.run_org(ctx.org)

      filled = reload(record).next_occurrence_at
      assert filled
      assert DateTime.diff(filled, Index.anchor(), :second) < 7 * 86_400
    end

    test "a past one-off stays NULL, and is not written", ctx do
      record = ctx |> event!(%{"when" => schedule(-30)}) |> unbackfilled!()
      before = reload(record)

      Backfill.run_org(ctx.org)

      after_run = reload(record)
      assert is_nil(after_run.next_occurrence_at)
      # nil -> nil is not a change, so the row must not be touched at all.
      assert after_run.updated_at == before.updated_at
    end
  end

  describe "it is safe to re-run" do
    test "a second pass writes nothing", ctx do
      for days <- [3, 10, 45], do: ctx |> event!(%{"when" => schedule(days)}) |> unbackfilled!()

      assert %{written: first} = Backfill.run_org(ctx.org)
      assert first == 3

      assert %{written: 0, scanned: scanned} = Backfill.run_org(ctx.org)
      # It still LOOKED at them — the skip is a comparison, not a narrower query.
      assert scanned >= 3
    end

    test "an already-correct row is not rewritten, precision notwithstanding", ctx do
      # A value round-tripped through Postgres comes back as `{n, 6}` microsecond
      # precision while a freshly computed one is `{0, 0}`, so struct equality
      # calls every unchanged row changed. If `refresh/3` ever regresses to `==`,
      # this is what fails.
      record = event!(ctx, %{"when" => schedule(30)})
      before = reload(record)
      assert before.next_occurrence_at

      Backfill.run_org(ctx.org)

      assert reload(record).updated_at == before.updated_at
    end
  end

  describe "which types it visits" do
    test "by default, only event-shaped ones", ctx do
      page =
        CMS.create_page!(
          %{title: "About", slug: "about-#{System.unique_integer([:positive])}"},
          actor: ctx.admin
        )

      for days <- [3, 10], do: ctx |> event!(%{"when" => schedule(days)}) |> unbackfilled!()

      %{scanned: scanned, written: written} = Backfill.run_org(ctx.org)

      # The two events, and nothing else. Pages are not an event-shaped type, so
      # their table is never scanned — which is the bound that keeps a backfill
      # from reading every content table on a site with one event type.
      assert scanned == 2
      assert written == 2
      assert is_nil(reload_page(page).next_occurrence_at)
    end

    test "all_types reaches a type that LOST its schedule field", ctx do
      # A future-dated stale value on a type that is no longer event-shaped:
      # invisible to the sweep (it has not passed) and to the default pass (the
      # type is not event-shaped). Nothing else will ever correct it.
      record = event!(ctx, %{"when" => schedule(30)})
      assert record.next_occurrence_at

      ctx.td.id
      |> CMS.field_definitions_for_definition!(authorize?: false)
      |> Enum.find(&(&1.name == "when"))
      |> CMS.destroy_field_definition!(actor: ctx.admin)

      KilnCMS.Events.Sweep.run_org(ctx.org)
      assert reload(record).next_occurrence_at, "the sweep should not have touched it"

      Backfill.run_org(ctx.org)
      assert reload(record).next_occurrence_at, "the default pass should not see this type"

      Backfill.run_org(ctx.org, all_types: true)
      assert is_nil(reload(record).next_occurrence_at)
    end
  end

  describe "paging" do
    test "a batch smaller than the row count still visits every row", ctx do
      records =
        for days <- 1..5, do: ctx |> event!(%{"when" => schedule(days)}) |> unbackfilled!()

      # Deliberately smaller than the set: this pass cannot drain the way the
      # sweep does — a corrected row still matches "every row" — so a paging bug
      # loops forever or stops after one page.
      assert %{written: 5} = Backfill.run_org(ctx.org, batch: 2)

      for record <- records, do: assert(reload(record).next_occurrence_at)
    end
  end

  defp reload_page(page), do: CMS.get_page!(page.id, authorize?: false)
end
