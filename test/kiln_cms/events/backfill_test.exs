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

  # Noon London, `days` after today's UTC date — never the current wall time,
  # which puts a weekly series an hour past the seven-day bound whenever the
  # suite runs in the small hours of the week before a DST change.
  defp schedule(days) do
    start = Date.utc_today() |> Date.add(days) |> NaiveDateTime.new!(~T[12:00:00])

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

  describe "trashed rows (#2621)" do
    # The pass stays live-only; `:restore` recomputes instead. The value is
    # relative to the clock, so one written into the trash would be stale
    # again by the time the row came out (see `Backfill`'s moduledoc).

    test "the pass skips a trashed row and the restore recomputes it", ctx do
      # The issue's own scenario: trash an event, run the backfill, restore.
      record =
        ctx
        |> event!(%{"when" => schedule(-365), "repeats" => %{"rrule" => "FREQ=WEEKLY"}})
        |> unbackfilled!()

      CMS.destroy_entry!(record, actor: ctx.admin)

      assert %{scanned: 0, written: 0} = Backfill.run_org(ctx.org)
      assert is_nil(trashed!(ctx, record).next_occurrence_at)

      CMS.restore_entry!(trashed!(ctx, record), actor: ctx.admin)

      restored = reload(record)
      assert restored.next_occurrence_at
      assert_same(restored.next_occurrence_at, Index.next_occurrence_at(restored, ctx.org))
    end

    for {label, offset} <- [{"future", 3 * 86_400 + 1234}, {"past", -10 * 86_400}] do
      test "a stale #{label} value is recomputed on restore", ctx do
        # A wrong future value is one the sweep never revisits, so restore
        # is the only thing that can correct it.
        stale = DateTime.add(Index.anchor(), unquote(offset))

        record =
          ctx
          |> event!(%{"when" => schedule(-365), "repeats" => %{"rrule" => "FREQ=WEEKLY"}})
          |> Ash.Seed.update!(%{next_occurrence_at: stale})

        CMS.destroy_entry!(record, actor: ctx.admin)
        CMS.restore_entry!(trashed!(ctx, record), actor: ctx.admin)

        restored = reload(record)
        refute DateTime.compare(restored.next_occurrence_at, stale) == :eq
        assert_same(restored.next_occurrence_at, Index.next_occurrence_at(restored, ctx.org))
      end
    end

    test "a past one-off comes back with no upcoming date", ctx do
      record =
        ctx
        |> event!(%{"when" => schedule(-30)})
        |> Ash.Seed.update!(%{next_occurrence_at: DateTime.add(Index.anchor(), 86_400)})

      CMS.destroy_entry!(record, actor: ctx.admin)
      CMS.restore_entry!(trashed!(ctx, record), actor: ctx.admin)

      assert is_nil(reload(record).next_occurrence_at)
    end

    test "restoring a struct read without custom_fields keeps the stored value", ctx do
      # `custom_fields` arrives as `%Ash.NotLoaded{}`; computing from it would
      # answer nil and wipe the sort key.
      stored = DateTime.add(Index.anchor(), 5 * 86_400)

      record =
        ctx
        |> event!(%{"when" => schedule(30)})
        |> Ash.Seed.update!(%{next_occurrence_at: stored})

      CMS.destroy_entry!(record, actor: ctx.admin)

      fields =
        Ash.Resource.Info.attribute_names(KilnCMS.CMS.Entry) |> MapSet.delete(:custom_fields)

      partial =
        [actor: ctx.admin, query: [select: MapSet.to_list(fields)]]
        |> CMS.list_trashed_entries!()
        |> Enum.find(&(&1.id == record.id))

      assert %Ash.NotLoaded{} = partial.custom_fields

      CMS.restore_entry!(partial, actor: ctx.admin)

      restored = reload(record)
      assert restored.custom_fields != %{}
      assert_same(restored.next_occurrence_at, stored)
    end

    test "a second restore of the held struct is still refused", ctx do
      record = event!(ctx, %{"when" => schedule(30)})
      CMS.destroy_entry!(record, actor: ctx.admin)
      held = trashed!(ctx, record)

      CMS.restore_entry!(held, actor: ctx.admin)

      assert {:error, _} = CMS.restore_entry(held, actor: ctx.admin)
    end

    test "the sort-key write stays refused on a trashed row" do
      refute :set_next_occurrence in KilnCMS.CMS.Changes.RefuseTrashed.exempt_actions()
    end
  end

  defp trashed!(ctx, record) do
    [actor: ctx.admin]
    |> CMS.list_trashed_entries!()
    |> Enum.find(&(&1.id == record.id))
  end

  defp assert_same(%DateTime{} = left, %DateTime{} = right),
    do: assert(DateTime.compare(left, right) == :eq, "#{left} != #{right}")

  defp reload_page(page), do: CMS.get_page!(page.id, authorize?: false)
end
