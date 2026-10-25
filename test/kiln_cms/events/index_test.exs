defmodule KilnCMS.Events.IndexTest do
  @moduledoc """
  The materialized sort key behind "what's on, soonest first" (#766).

  The claims worth testing here are the ones the whole design rests on: that
  the value is written from the *coerced* schedule, that `nil` means "never
  again" rather than "not soon", and that the day anchor is a local day in the
  event timezone rather than a UTC one.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Events
  alias KilnCMS.Events.Index

  @london "Europe/London"
  # Ahead of UTC by 13 hours in January — far enough that "the start of today"
  # is a different instant depending on which day you mean.
  @auckland "Pacific/Auckland"

  setup do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "idx-#{System.unique_integer([:positive])}@example.com",
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

    %{admin: admin, td: td, type: name, org: KilnCMS.Accounts.default_org_id()}
  end

  defp with_recurrence(ctx) do
    CMS.create_field_definition!(
      %{
        type_definition_id: ctx.td.id,
        name: "repeats",
        label: "Repeats",
        field_type: "recurrence"
      },
      actor: ctx.admin
    )

    ctx
  end

  defp event!(ctx, fields, attrs \\ %{}) do
    CMS.create_entry!(
      Map.merge(
        %{
          title: "A gig",
          slug: "ev-#{System.unique_integer([:positive])}",
          type_definition_id: ctx.td.id,
          custom_fields: fields
        },
        attrs
      ),
      actor: ctx.admin
    )
  end

  defp local(%DateTime{} = utc, zone) do
    utc |> DateTime.shift_zone!(zone) |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
  end

  # Noon London wall time, `days` after today's UTC date. Never "now + N days":
  # the current wall time falls in a DST gap, or within a weekly bound's last
  # hour, whenever the suite runs at the matching hour before a change.
  defp noon_london(days) do
    Date.utc_today()
    |> Date.add(days)
    |> NaiveDateTime.new!(~T[12:00:00])
    |> NaiveDateTime.to_iso8601()
  end

  describe "the value written on save" do
    test "a future one-off is stored as its own start instant", ctx do
      # 30 days out, at noon London — expressed as local wall time, which is
      # what the field stores.
      start = noon_london(30)

      record = event!(ctx, %{"when" => %{"start" => start, "time_zone" => @london}})

      assert %DateTime{} = record.next_occurrence_at
      # The instant round-trips through the zone rather than being taken as UTC:
      # noon London in summer is 11:00Z, so a naive reading would be an hour out.
      stored = record.next_occurrence_at |> local(@london) |> NaiveDateTime.from_iso8601!()
      assert NaiveDateTime.compare(stored, NaiveDateTime.from_iso8601!(start)) == :eq
    end

    test "a past one-off has nothing coming up", ctx do
      record = event!(ctx, %{"when" => %{"start" => noon_london(-30), "time_zone" => @london}})

      assert is_nil(record.next_occurrence_at)
    end

    test "an event EARLIER TODAY is still coming up", ctx do
      # The anchor is the start of the local day, not `now()` — a gig whose
      # doors opened this morning is still what's on today. Anchoring at the
      # current instant is the bug this guards.
      #
      # The start has to fall between the anchor and now, and it has to be
      # derived from BOTH: a fixed offset from the anchor ("anchor + 60s") is
      # still in the future for the first minute of every day (#1602). Halfway
      # between the two always qualifies, whatever the time of day. Truncated
      # to the second because the field stores wall time at that precision; in
      # the day's first second that lands on the anchor itself, which still
      # proves the point — it is before `now`, so a `now()` anchor answers nil.
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      anchor = Index.anchor(now)
      this_morning = DateTime.add(anchor, div(DateTime.diff(now, anchor, :second), 2), :second)

      wall = local(this_morning, @london)

      # The field stores wall time, and wall time cannot always name the instant
      # it came from: in the repeated hour of an autumn-back day, `this_morning`
      # may be the SECOND 01:05, and the field reads 01:05 as the first (see
      # "the DST changeover days" below). So the expectation is the instant the
      # stored wall time means, not `this_morning` itself. It still lies between
      # the anchor and now — the first of a pair is earlier, never before the
      # local midnight — so the claim this guards is unchanged.
      {:ok, starts_at} = Events.to_utc(NaiveDateTime.from_iso8601!(wall), @london)

      assert DateTime.compare(starts_at, anchor) in [:gt, :eq]
      assert DateTime.compare(starts_at, now) in [:lt, :eq]

      record = event!(ctx, %{"when" => %{"start" => wall, "time_zone" => @london}})

      # Its own start, not nil and not some later instant: a one-off that began
      # this morning is materialized as exactly when it began.
      assert record.next_occurrence_at
      assert DateTime.compare(record.next_occurrence_at, starts_at) == :eq
    end

    test "a recurring event whose series started in the past points at its NEXT date", ctx do
      ctx = with_recurrence(ctx)
      # Started a year ago, weekly, forever.
      record =
        event!(ctx, %{
          "when" => %{"start" => noon_london(-365), "time_zone" => @london},
          "repeats" => %{"rrule" => "FREQ=WEEKLY"}
        })

      assert record.next_occurrence_at
      assert DateTime.compare(record.next_occurrence_at, Index.anchor()) != :lt
      # Within a week of the anchor: a weekly series has an occurrence in every
      # seven-day span, so anything further out means the walk started in the
      # wrong place.
      assert DateTime.diff(record.next_occurrence_at, Index.anchor(), :second) < 7 * 86_400
    end

    test "an exhausted series has nothing coming up", ctx do
      ctx = with_recurrence(ctx)

      record =
        event!(ctx, %{
          "when" => %{"start" => noon_london(-365), "time_zone" => @london},
          "repeats" => %{"rrule" => "FREQ=WEEKLY;COUNT=3"}
        })

      assert is_nil(record.next_occurrence_at)
    end

    test "nil is TERMINAL, not 'not soon' — a two-year-out event is materialized", ctx do
      # The horizon is a decade precisely so that `nil` never has to be
      # revisited. A 400-day horizon would have answered nil here and made the
      # sweep re-scan every past event forever.
      record = event!(ctx, %{"when" => %{"start" => noon_london(730), "time_zone" => @london}})

      assert record.next_occurrence_at
      assert Index.horizon_days() > 730
    end

    test "a document whose type carries no schedule field gets nil", ctx do
      page =
        CMS.create_page!(
          %{title: "About", slug: "about-#{System.unique_integer([:positive])}"},
          actor: ctx.admin
        )

      assert is_nil(page.next_occurrence_at)
    end

    test "a document with no custom fields at all costs no definitions read", ctx do
      # The short-circuit in `SetNextOccurrence`: this runs on every save,
      # autosaves included, and asking the database which fields a type has for
      # a document that carries none is a query per keystroke pause for an
      # answer that can only be nil.
      page =
        CMS.create_page!(
          %{title: "About", slug: "about-#{System.unique_integer([:positive])}"},
          actor: ctx.admin
        )

      assert page.custom_fields == %{}

      # Sound rather than approximate: no fields means no schedule means nil,
      # and the assertion above is what makes that implication hold.
      assert is_nil(page.next_occurrence_at)
    end

    test "clearing the schedule clears the sort key", ctx do
      record = event!(ctx, %{"when" => %{"start" => noon_london(30), "time_zone" => @london}})

      assert record.next_occurrence_at

      updated = CMS.update_entry!(record, %{custom_fields: %{"when" => ""}}, actor: ctx.admin)

      assert is_nil(updated.next_occurrence_at)
    end
  end

  describe "the day anchor" do
    setup do
      original = Application.get_env(:kiln_cms, KilnCMS.Events, [])
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Events, original) end)
      :ok
    end

    test "is midnight in the deployment's event zone, not in UTC" do
      Application.put_env(:kiln_cms, KilnCMS.Events, time_zone: @auckland)

      # 2026-01-15 10:00 UTC is 2026-01-15 23:00 in Auckland — so the local day
      # started at 2026-01-14 11:00 UTC. A UTC reading would answer 00:00Z on
      # the 15th, which is thirteen hours into the Auckland day and would drop
      # everything already past that morning.
      now = ~U[2026-01-15 10:00:00Z]

      anchor = Index.anchor(now)

      assert anchor == ~U[2026-01-14 11:00:00Z]
      assert Events.default_time_zone() == @auckland
    end

    test "on a changeover day is local midnight in the offset midnight had" do
      Application.put_env(:kiln_cms, KilnCMS.Events, time_zone: @london)

      # Autumn back: midnight on 2026-10-25 is still BST, so the day began at
      # 23:00Z the evening before, not at 00:00Z.
      assert Index.anchor(~U[2026-10-25 02:10:00Z]) == ~U[2026-10-24 23:00:00Z]
      # Spring forward: midnight on 2026-03-29 is still GMT.
      assert Index.anchor(~U[2026-03-29 10:00:00Z]) == ~U[2026-03-29 00:00:00Z]
    end

    test "sits at or before now, and no more than a day back" do
      anchor = Index.anchor()

      assert DateTime.compare(anchor, DateTime.utc_now()) in [:lt, :eq]
      assert DateTime.diff(DateTime.utc_now(), anchor, :second) < 86_400 + 3600
    end
  end

  # Pinned instants on Europe/London's 2026 changeovers, so these run the same
  # whatever day the suite does. `next_occurrence_at/3` takes `from`, and the
  # record's own saved value (computed against the real clock) is ignored.
  describe "the DST changeover days" do
    setup do
      original = Application.get_env(:kiln_cms, KilnCMS.Events, [])
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Events, original) end)
      :ok
    end

    test "a wall time in the repeated autumn hour is the FIRST of the pair", ctx do
      Application.put_env(:kiln_cms, KilnCMS.Events, time_zone: @london)
      from = Index.anchor(~U[2026-10-25 02:10:00Z])

      record =
        event!(ctx, %{"when" => %{"start" => "2026-10-25T01:30:00", "time_zone" => @london}})

      # 01:30 BST (00:30Z), not 01:30 GMT (01:30Z) — the rule `docs/events.md`
      # states and `KilnCMS.Events.Recurrence` applies to every occurrence.
      assert Index.next_occurrence_at(record, ctx.org, from) == ~U[2026-10-25 00:30:00Z]
    end

    test "an event in the second 01:xx of the autumn-back day is still today's", ctx do
      # The suite failure of 2026-10-25, pinned. A UTC deployment at 02:10Z: the day
      # began at 00:00Z, and halfway to now is 01:05Z — 01:05 GMT in London,
      # the SECOND 01:05. Stored as wall time it reads back as the first
      # (00:05Z): an hour earlier than the instant the test started from, and
      # still after the anchor, so still on today's listing.
      Application.put_env(:kiln_cms, KilnCMS.Events, time_zone: "Etc/UTC")
      from = Index.anchor(~U[2026-10-25 02:10:00Z])
      assert from == ~U[2026-10-25 00:00:00Z]

      record =
        event!(ctx, %{"when" => %{"start" => "2026-10-25T01:05:00", "time_zone" => @london}})

      assert Index.next_occurrence_at(record, ctx.org, from) == ~U[2026-10-25 00:05:00Z]
    end

    test "a wall time in the spring-forward gap moves past it rather than vanishing", ctx do
      Application.put_env(:kiln_cms, KilnCMS.Events, time_zone: @london)
      from = Index.anchor(~U[2026-03-29 10:00:00Z])

      # 01:30 does not exist on 2026-03-29: clocks jump from 01:00 GMT to 02:00
      # BST. The event lands at the far edge of the gap, 02:00 BST (01:00Z).
      gap = event!(ctx, %{"when" => %{"start" => "2026-03-29T01:30:00", "time_zone" => @london}})
      assert Index.next_occurrence_at(gap, ctx.org, from) == ~U[2026-03-29 01:00:00Z]

      # Either side of the gap is an ordinary wall time in its own offset.
      before =
        event!(ctx, %{"when" => %{"start" => "2026-03-29T00:30:00", "time_zone" => @london}})

      assert Index.next_occurrence_at(before, ctx.org, from) == ~U[2026-03-29 00:30:00Z]

      later =
        event!(ctx, %{"when" => %{"start" => "2026-03-29T02:30:00", "time_zone" => @london}})

      assert Index.next_occurrence_at(later, ctx.org, from) == ~U[2026-03-29 01:30:00Z]
    end
  end
end
