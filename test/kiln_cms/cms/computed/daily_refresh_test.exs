defmodule KilnCMS.CMS.Computed.DailyRefreshTest do
  @moduledoc """
  Date-relative computed fields end to end: `today()` is pinned once per
  evaluation pass, so a record's stored value and its fired artifact agree on
  the same day, and the daily refresh moves both when the day changes.

  Every date here is injected — through the changeset context, `today:` on the
  fire, or `today:` on the refresh — and none is read off the wall clock, so
  the suite means the same thing on any day it runs.
  """
  use KilnCMS.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Computed.Context
  alias KilnCMS.CMS.Computed.DailyRefresh
  alias KilnCMS.Firing
  alias KilnCMS.SystemActor

  @monday ~D[2026-10-19]
  @tuesday ~D[2026-10-20]
  @event "2026-10-23"

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "daily-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp org_id, do: Accounts.default_org_id()
  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  # A date field and a countdown to it.
  defp countdown_fields(actor, compute \\ "{{ days_between(today(), event_on) }}") do
    CMS.create_field_definition!(
      %{content_type: :page, name: "event_on", label: "Event on", field_type: :date},
      actor: actor
    )

    CMS.create_field_definition!(
      %{
        content_type: :page,
        name: unique("countdown"),
        label: "Countdown",
        field_type: :computed,
        compute: compute
      },
      actor: actor
    )
  end

  defp page!(actor, today, attrs \\ %{}) do
    CMS.create_page!(
      Map.merge(
        %{
          title: "Gig",
          slug: "gig-#{System.unique_integer([:positive])}",
          custom_fields: %{"event_on" => @event}
        },
        attrs
      ),
      actor: actor,
      context: Context.pinned_context(today)
    )
  end

  defp published!(actor, today) do
    actor
    |> page!(today)
    |> CMS.publish_page!(actor: actor, context: Context.pinned_context(today))
  end

  defp fire_jobs(id) do
    worker = inspect(Firing.FireWorker)

    # Pending only: a drained job stays in the table as completed.
    from(j in Oban.Job,
      where:
        j.worker == ^worker and j.state in ["available", "scheduled"] and
          fragment("?->>'id'", j.args) == ^id
    )
    |> Repo.all()
  end

  defp artifact_value(page, name) do
    {:ok, artifact} =
      Firing.get_artifact(:page, page.id, :json,
        actor: SystemActor.new(:firing),
        tenant: org_id()
      )

    artifact.body["custom_fields"][name]
  end

  describe "one day, one answer" do
    test "the write and the fire agree on the pinned day" do
      actor = admin()
      countdown = countdown_fields(actor)

      page = page!(actor, @monday)
      assert page.custom_fields[countdown.name] == 4

      %{values: values} = Firing.CustomFields.resolve(page, nil, today: @monday)
      assert values[countdown.name] == 4

      {:ok, %{json: json}} = Firing.Engine.fire(page, mode: :preview, today: @monday)
      assert json["custom_fields"][countdown.name] == 4
    end

    test "the fire a publish enqueues carries the date its write pinned" do
      actor = admin()
      countdown = countdown_fields(actor)

      page = published!(actor, @monday)
      assert page.custom_fields[countdown.name] == 4

      assert [%{args: %{"today" => "2026-10-19"}}] = fire_jobs(page.id)

      # The worker fires on Monday whatever day the suite runs on — a fire
      # reached after the site's midnight still matches what was stored.
      drain_oban()
      assert artifact_value(page, countdown.name) == 4
    end

    test "a publish re-derives on the publish day, not the last save's" do
      actor = admin()
      countdown = countdown_fields(actor)

      page = page!(actor, @monday)
      assert page.custom_fields[countdown.name] == 4

      published = CMS.publish_page!(page, actor: actor, context: Context.pinned_context(@tuesday))
      assert published.custom_fields[countdown.name] == 3
      assert [%{args: %{"today" => "2026-10-20"}}] = fire_jobs(page.id)
    end

    test "a write's slug and fields see one date" do
      actor = admin()
      countdown = countdown_fields(actor)

      changeset =
        Ash.Changeset.for_create(
          CMS.Page,
          :create,
          %{
            title: "Gig",
            slug: "gig-#{System.unique_integer([:positive])}",
            custom_fields: %{"event_on" => @event}
          },
          actor: actor,
          context: Context.pinned_context(@monday)
        )

      # Pinned by the caller, so nothing in the action re-reads the clock.
      assert Context.pinned_today(changeset) == @monday
      assert Context.pin_today(changeset).context.computed_today == @monday

      {:ok, page} = Ash.create(changeset)
      assert page.custom_fields[countdown.name] == 4
    end
  end

  describe "the daily refresh" do
    test "moves the stored value and the artifact to the new day" do
      actor = admin()
      countdown = countdown_fields(actor)
      page = published!(actor, @monday)
      drain_oban()
      assert artifact_value(page, countdown.name) == 4

      assert DailyRefresh.run_org(org_id(), today: @tuesday) == 1

      refreshed = CMS.get_page!(page.id, actor: actor)
      assert refreshed.custom_fields[countdown.name] == 3
      assert [%{args: %{"today" => "2026-10-20"}}] = fire_jobs(page.id)

      drain_oban()
      assert artifact_value(page, countdown.name) == 3

      # Same day again: nothing moves, so nothing is written or re-fired.
      assert DailyRefresh.run_org(org_id(), today: @tuesday) == 0
      assert fire_jobs(page.id) == []
    end

    test "is not an editorial change: the lock and updated_at stay, a version is cut" do
      actor = admin()
      countdown = countdown_fields(actor)
      page = published!(actor, @monday)
      before = CMS.get_page!(page.id, actor: actor)

      assert DailyRefresh.run_org(org_id(), today: @tuesday) == 1

      after_refresh = CMS.get_page!(page.id, actor: actor)
      assert after_refresh.custom_fields[countdown.name] == 3
      assert after_refresh.lock_version == before.lock_version
      assert after_refresh.updated_at == before.updated_at

      # Versioned, so the sync delta API reports the moved value.
      versions = CMS.list_page_versions!(actor: actor, tenant: org_id())

      assert Enum.any?(
               versions,
               &(&1.version_source_id == page.id and &1.version_action_name == :refresh_computed)
             )
    end

    test "leaves drafts to their next save and types without a today() formula alone" do
      actor = admin()
      countdown = countdown_fields(actor)
      draft = page!(actor, @monday)

      assert DailyRefresh.run_org(org_id(), today: @tuesday) == 0
      assert CMS.get_page!(draft.id, actor: actor).custom_fields[countdown.name] == 4

      CMS.update_field_definition!(countdown, %{compute: "{{ word_count(body) }}"}, actor: actor)
      assert DailyRefresh.time_dependent_types(org_id()) == []
    end

    @tag :capture_log
    test "loses to an editor who saved after it read" do
      actor = admin()
      countdown = countdown_fields(actor)
      page = published!(actor, @monday)
      stale = CMS.get_page!(page.id, actor: actor)

      CMS.update_page!(stale, %{custom_fields: %{"event_on" => "2026-10-30"}},
        actor: actor,
        context: Context.pinned_context(@monday)
      )

      assert {:error, _stale} = DailyRefresh.refresh(stale, org_id(), @tuesday)

      kept = CMS.get_page!(page.id, actor: actor)
      assert kept.custom_fields["event_on"] == "2026-10-30"
      assert kept.custom_fields[countdown.name] == 11
    end

    test "moves an age once a year, not every night" do
      actor = admin()

      CMS.create_field_definition!(
        %{content_type: :page, name: "born", label: "Born", field_type: :date},
        actor: actor
      )

      age =
        CMS.create_field_definition!(
          %{
            content_type: :page,
            name: unique("age"),
            label: "Age",
            field_type: :computed,
            compute: "{{ years_between(born, today()) }}"
          },
          actor: actor
        )

      page =
        actor
        |> page!(@monday, %{custom_fields: %{"born" => "1990-10-20"}})
        |> CMS.publish_page!(actor: actor, context: Context.pinned_context(@monday))

      assert page.custom_fields[age.name] == 35
      assert DailyRefresh.run_org(org_id(), today: ~D[2026-10-19]) == 0
      assert DailyRefresh.run_org(org_id(), today: @tuesday) == 1
      assert CMS.get_page!(page.id, actor: actor).custom_fields[age.name] == 36
    end
  end

  describe "the scheduled action" do
    test "runs for the scheduler and the computed_fields system actor only" do
      actor = admin()
      countdown_fields(actor)
      published!(actor, @monday)

      assert {:ok, 1} =
               CMS.refresh_time_dependent_fields(@tuesday,
                 actor: SystemActor.new(:computed_fields)
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.refresh_time_dependent_fields(@tuesday, actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.refresh_time_dependent_fields(@tuesday, actor: SystemActor.new(:firing))
    end

    test "a tick without a date does nothing unless the site's day just changed" do
      # 05:07 UTC is not the first tick after midnight anywhere this suite's
      # deployment zone (UTC by default) puts it.
      refute DailyRefresh.due?(~U[2026-10-20 05:07:00Z])
      assert DailyRefresh.tick(now: ~U[2026-10-20 05:07:00Z]) == 0
    end
  end
end

defmodule KilnCMS.CMS.Computed.DailyRefreshDueTest do
  @moduledoc """
  When the hourly tick does the day's work: the first tick after the SITE's
  midnight, in the deployment's zone. Not async — the zone is application
  config.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.CMS.Computed.Context
  alias KilnCMS.CMS.Computed.DailyRefresh

  setup do
    previous = Application.get_env(:kiln_cms, KilnCMS.Events)
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Events, previous || []) end)
  end

  defp in_zone(zone), do: Application.put_env(:kiln_cms, KilnCMS.Events, time_zone: zone)

  test "in UTC, the 00:07 tick is the day's" do
    in_zone("Etc/UTC")
    assert DailyRefresh.due?(~U[2026-10-20 00:07:00Z])
    refute DailyRefresh.due?(~U[2026-10-20 01:07:00Z])
    refute DailyRefresh.due?(~U[2026-10-19 23:07:00Z])
  end

  test "on a site west of UTC, the day turns at its own midnight, not UTC's" do
    in_zone("America/Los_Angeles")

    # 00:07 UTC is 17:07 the previous afternoon in Los Angeles.
    refute DailyRefresh.due?(~U[2026-10-20 00:07:00Z])
    assert Context.today(~U[2026-10-20 00:07:00Z]) == ~D[2026-10-19]

    # 07:07 UTC is 00:07 PDT.
    assert DailyRefresh.due?(~U[2026-10-20 07:07:00Z])
    assert Context.today(~U[2026-10-20 07:07:00Z]) == ~D[2026-10-20]
  end

  test "exactly one tick a day is due, across a DST change and a half-hour offset" do
    # Three weeks of hourly ticks over both 2026 fall-back days (25 October in
    # Europe, 1 November in the US): the due ticks land on consecutive site
    # days, one each — no day skipped, none refreshed twice.
    ticks = for hour <- 0..(21 * 24), do: DateTime.add(~U[2026-10-18 00:07:00Z], hour * 3600)

    for zone <- ["America/Los_Angeles", "Asia/Kolkata", "Europe/London"] do
      in_zone(zone)

      days = for tick <- ticks, DailyRefresh.due?(tick), do: Context.today(tick)

      assert days == Enum.to_list(Date.range(hd(days), List.last(days))),
             "#{zone}: #{inspect(days)}"

      assert length(days) >= 20
    end
  end
end
