defmodule KilnCMS.Events.SweepTest do
  @moduledoc """
  The sweep that advances `next_occurrence_at` once an occurrence has gone by
  (#766).

  Two things matter here and they pull in opposite directions: it has to visit
  every row whose value has passed, and it has to leave no editorial trace on
  any of them — no version, no lock bump, no webhook. A sweep that is correct
  and noisy is a sweep that makes an open editor's next save fail because a gig
  ended.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Events.Index
  alias KilnCMS.Events.Sweep

  @london "Europe/London"

  setup do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "swp-#{System.unique_integer([:positive])}@example.com",
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

  defp local(%DateTime{} = utc), do: utc |> DateTime.shift_zone!(@london) |> DateTime.to_naive()

  defp schedule(start),
    do: %{"start" => NaiveDateTime.to_iso8601(local(start)), "time_zone" => @london}

  # Put a row into the state the sweep exists to correct: a stored value that has
  # since gone by. Written straight to the row, because the whole point is that
  # nothing WROTE the record — time simply passed.
  defp stale!(record, at) do
    Ash.Seed.update!(record, %{next_occurrence_at: at})
  end

  defp reload(record), do: CMS.get_entry!(record.id, authorize?: false)

  describe "what it visits" do
    test "advances a recurring event whose date has gone by", ctx do
      start = DateTime.utc_now() |> DateTime.add(-365 * 86_400, :second)

      record =
        event!(ctx, %{"when" => schedule(start), "repeats" => %{"rrule" => "FREQ=WEEKLY"}})

      # Pretend last week's occurrence is the one on the row.
      stale!(record, DateTime.add(Index.anchor(), -3 * 86_400, :second))

      assert Sweep.run_org(ctx.org) >= 1

      advanced = reload(record)
      assert DateTime.compare(advanced.next_occurrence_at, Index.anchor()) != :lt
    end

    test "clears a series that has ended", ctx do
      start = DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second)
      record = event!(ctx, %{"when" => schedule(start)})

      # A one-off in the past materialized as nil on save; force it back to a
      # stale value so the sweep has something to find.
      stale!(record, DateTime.add(Index.anchor(), -86_400, :second))

      Sweep.run_org(ctx.org)

      assert is_nil(reload(record).next_occurrence_at)
    end

    test "leaves a FUTURE value alone", ctx do
      start = DateTime.utc_now() |> DateTime.add(30 * 86_400, :second)
      record = event!(ctx, %{"when" => schedule(start)})

      assert record.next_occurrence_at
      before = reload(record)

      Sweep.run_org(ctx.org)

      after_sweep = reload(record)
      assert after_sweep.next_occurrence_at == before.next_occurrence_at
      # Untouched, not merely unchanged: a value that is still in the future is
      # correct by construction, so the sweep must not even write it.
      assert after_sweep.updated_at == before.updated_at
    end

    test "sweeps a type that has LOST its schedule field", ctx do
      # The rows a `calendar_types/1`-scoped sweep would strand forever: delete
      # the schedule field and the type is no longer event-shaped, but its rows
      # still carry a sort key that will never be corrected by anything else.
      start = DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second)
      record = event!(ctx, %{"when" => schedule(start)})
      stale!(record, DateTime.add(Index.anchor(), -86_400, :second))

      ctx.td.id
      |> CMS.field_definitions_for_definition!(authorize?: false)
      |> Enum.find(&(&1.name == "when"))
      |> CMS.destroy_field_definition!(actor: ctx.admin)

      Sweep.run_org(ctx.org)

      assert is_nil(reload(record).next_occurrence_at)
    end
  end

  describe "what it must not do" do
    setup ctx do
      start = DateTime.utc_now() |> DateTime.add(-365 * 86_400, :second)

      record =
        event!(ctx, %{"when" => schedule(start), "repeats" => %{"rrule" => "FREQ=WEEKLY"}})

      published = CMS.publish_entry!(record, actor: ctx.admin)
      stale!(published, DateTime.add(Index.anchor(), -3 * 86_400, :second))

      %{record: reload(published)}
    end

    test "cuts no history version", %{record: record} = ctx do
      before = length(CMS.list_entry_versions!(authorize?: false))

      Sweep.run_org(ctx.org)

      assert length(CMS.list_entry_versions!(authorize?: false)) == before
      # And it really did do the work — otherwise this asserts nothing.
      assert reload(record).next_occurrence_at != record.next_occurrence_at
    end

    test "does not bump lock_version, so an open editor's next save still lands",
         %{record: record} = ctx do
      Sweep.run_org(ctx.org)

      assert reload(record).lock_version == record.lock_version

      # The proof that matters: the struct the editor is holding still saves.
      assert {:ok, _saved} = CMS.update_entry(record, %{title: "Renamed"}, actor: ctx.admin)
    end
  end
end
