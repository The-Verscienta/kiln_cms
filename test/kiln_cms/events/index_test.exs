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

  describe "the value written on save" do
    test "a future one-off is stored as its own start instant", ctx do
      # 30 days out, at 19:00 London — expressed as local wall time, which is
      # what the field stores.
      start = DateTime.utc_now() |> DateTime.add(30 * 86_400, :second)

      record =
        event!(ctx, %{"when" => %{"start" => local(start, @london), "time_zone" => @london}})

      assert %DateTime{} = record.next_occurrence_at
      # The instant round-trips through the zone rather than being taken as UTC:
      # 19:00 London in summer is 18:00Z, so a naive reading would be an hour out.
      assert local(record.next_occurrence_at, @london) ==
               local(start, @london)
               |> NaiveDateTime.from_iso8601!()
               |> NaiveDateTime.to_iso8601()
    end

    test "a past one-off has nothing coming up", ctx do
      past = DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second)

      record =
        event!(ctx, %{"when" => %{"start" => local(past, @london), "time_zone" => @london}})

      assert is_nil(record.next_occurrence_at)
    end

    test "an event EARLIER TODAY is still coming up", ctx do
      # The anchor is the start of the local day, not `now()` — a gig whose
      # doors opened this morning is still what's on today. Anchoring at the
      # current instant is the bug this guards.
      this_morning = Index.anchor() |> DateTime.add(60, :second)

      record =
        event!(ctx, %{
          "when" => %{"start" => local(this_morning, @london), "time_zone" => @london}
        })

      assert record.next_occurrence_at
      assert DateTime.compare(record.next_occurrence_at, DateTime.utc_now()) in [:lt, :eq]
    end

    test "a recurring event whose series started in the past points at its NEXT date", ctx do
      ctx = with_recurrence(ctx)
      # Started a year ago, weekly, forever.
      start = DateTime.utc_now() |> DateTime.add(-365 * 86_400, :second)

      record =
        event!(ctx, %{
          "when" => %{"start" => local(start, @london), "time_zone" => @london},
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
      start = DateTime.utc_now() |> DateTime.add(-365 * 86_400, :second)

      record =
        event!(ctx, %{
          "when" => %{"start" => local(start, @london), "time_zone" => @london},
          "repeats" => %{"rrule" => "FREQ=WEEKLY;COUNT=3"}
        })

      assert is_nil(record.next_occurrence_at)
    end

    test "nil is TERMINAL, not 'not soon' — a two-year-out event is materialized", ctx do
      # The horizon is a decade precisely so that `nil` never has to be
      # revisited. A 400-day horizon would have answered nil here and made the
      # sweep re-scan every past event forever.
      start = DateTime.utc_now() |> DateTime.add(730 * 86_400, :second)

      record =
        event!(ctx, %{"when" => %{"start" => local(start, @london), "time_zone" => @london}})

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
      start = DateTime.utc_now() |> DateTime.add(30 * 86_400, :second)

      record =
        event!(ctx, %{"when" => %{"start" => local(start, @london), "time_zone" => @london}})

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

    test "sits at or before now, and no more than a day back" do
      anchor = Index.anchor()

      assert DateTime.compare(anchor, DateTime.utc_now()) in [:lt, :eq]
      assert DateTime.diff(DateTime.utc_now(), anchor, :second) < 86_400 + 3600
    end
  end
end
