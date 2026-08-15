defmodule KilnCMS.CMS.CalendarTest do
  @moduledoc """
  The calendar projection: the union query behind `/editor/calendar`.

  Tested apart from the LiveView because the interesting failures are query
  failures — a lane that silently drops out, a window that includes its own
  exclusive bound, a filter that widens instead of narrowing — and none of those
  are legible through rendered HTML.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cal-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # The projection takes the org the console is scoped to, which in a DataCase
  # is the default one every fixture above lands in.
  defp org do
    Ash.get!(KilnCMS.Accounts.Organization, KilnCMS.Accounts.default_org_id(), authorize?: false)
  end

  defp slug, do: "cal-#{System.unique_integer([:positive])}"

  # A window wide enough that "today" never falls outside it, and every fixture
  # below is placed relative to `now` inside it.
  defp window do
    now = DateTime.utc_now()
    {DateTime.add(now, -30 * 86_400, :second), DateTime.add(now, 30 * 86_400, :second)}
  end

  defp events(actor, filters \\ %{}) do
    {from, to} = window()
    KilnCMS.CMS.Calendar.events(actor, org(), from, to, filters)
  end

  defp kinds_for(events, id), do: events |> Enum.filter(&(&1.id == id)) |> Enum.map(& &1.kind)

  defp in_days(n), do: DateTime.add(DateTime.utc_now(), n * 86_400, :second)

  describe "lanes" do
    test "a scheduled draft contributes a publish event" do
      admin = user(:admin)

      page =
        CMS.create_page!(
          %{title: "Launch", slug: slug(), scheduled_at: in_days(3)},
          actor: admin
        )

      assert kinds_for(events(admin), page.id) == [:publish]
    end

    test "a published record contributes its go-live" do
      admin = user(:admin)
      page = CMS.create_page!(%{title: "Live", slug: slug()}, actor: admin)
      page = CMS.publish_page!(page, %{}, actor: admin)

      assert :published in kinds_for(events(admin), page.id)
    end

    test "the embargo end's kind follows expiry_action" do
      admin = user(:admin)

      for {action, kind} <- [{:unpublish, :unpublish}, {:archive, :archive}, {:flag, :expire}] do
        page =
          CMS.create_page!(%{title: "Embargoed", slug: slug(), expiry_action: action},
            actor: admin
          )

        page = CMS.publish_page!(page, %{}, actor: admin)
        page = CMS.update_page!(page, %{unpublish_at: in_days(5)}, actor: admin)

        assert kind in kinds_for(events(admin), page.id),
               "expiry_action #{action} should plot as #{kind}"
      end
    end

    test "a review cadence contributes a review_due event at due_at" do
      admin = user(:admin)

      page =
        CMS.create_page!(%{title: "Monograph", slug: slug(), review_after_days: 10},
          actor: admin
        )

      page = CMS.publish_page!(page, %{}, actor: admin)

      [event] = events(admin) |> Enum.filter(&(&1.id == page.id and &1.kind == :review_due))

      # Never reviewed, so due_at counts from the publish — about ten days out.
      assert_in_delta DateTime.diff(event.at, in_days(10)), 0, 120
      assert event.health == :fresh
    end

    test "an overdue record's review_due event carries its health" do
      admin = user(:admin)

      page =
        CMS.create_page!(%{title: "Stale", slug: slug(), review_after_days: 5}, actor: admin)

      page = CMS.publish_page!(page, %{}, actor: admin)

      page
      |> Ash.Changeset.for_update(:backdate_published_at, %{published_at: in_days(-20)})
      |> Ash.update!(authorize?: false)

      [event] = events(admin) |> Enum.filter(&(&1.id == page.id and &1.kind == :review_due))
      assert event.health == :overdue
    end

    test "an open task contributes a task_due event resolving its content title" do
      admin = user(:admin)
      page = CMS.create_page!(%{title: "Needs work", slug: slug()}, actor: admin)

      CMS.assign_task!(
        %{
          content_type: "page",
          content_id: page.id,
          assignee_id: admin.id,
          due_on: Date.add(Date.utc_today(), 4)
        },
        actor: admin
      )

      [event] = events(admin) |> Enum.filter(&(&1.kind == :task_due and &1.id == page.id))
      assert event.title == "Needs work"
    end

    test "a scheduled release contributes a go-live event" do
      admin = user(:admin)

      release =
        CMS.create_release!(%{name: "Autumn launch"}, actor: admin)
        |> CMS.schedule_release!(%{scheduled_at: in_days(6)}, actor: admin)

      [event] = events(admin) |> Enum.filter(&(&1.id == release.id))
      assert event.kind == :release_scheduled
      assert event.title == "Autumn launch"
      assert event.type == :release
    end
  end

  describe "the window" do
    test "excludes events outside it, on both sides" do
      admin = user(:admin)

      too_early =
        CMS.create_page!(%{title: "Old", slug: slug(), scheduled_at: in_days(-90)}, actor: admin)

      too_late =
        CMS.create_page!(%{title: "Far", slug: slug(), scheduled_at: in_days(90)}, actor: admin)

      ids = events(admin) |> Enum.map(& &1.id)
      refute too_early.id in ids
      refute too_late.id in ids
    end

    test "`to` is exclusive" do
      admin = user(:admin)
      {from, to} = window()

      boundary =
        CMS.create_page!(%{title: "Boundary", slug: slug(), scheduled_at: to}, actor: admin)

      ids =
        KilnCMS.CMS.Calendar.events(admin, org(), from, to) |> Enum.map(& &1.id)

      refute boundary.id in ids

      # …and inclusive one second earlier, so the exclusion is the bound and not
      # an off-by-a-day in the query.
      widened = DateTime.add(to, 1, :second)
      ids = KilnCMS.CMS.Calendar.events(admin, org(), from, widened) |> Enum.map(& &1.id)
      assert boundary.id in ids
    end
  end

  describe "filters" do
    test "types narrows to the named content types" do
      admin = user(:admin)

      page =
        CMS.create_page!(%{title: "P", slug: slug(), scheduled_at: in_days(2)}, actor: admin)

      post =
        CMS.create_post!(%{title: "Q", slug: slug(), scheduled_at: in_days(2)}, actor: admin)

      ids = events(admin, %{types: ["page"]}) |> Enum.map(& &1.id)
      assert page.id in ids
      refute post.id in ids
    end

    test "an empty type list means nothing, not everything" do
      admin = user(:admin)
      CMS.create_page!(%{title: "P", slug: slug(), scheduled_at: in_days(2)}, actor: admin)

      assert events(admin, %{types: []}) |> Enum.filter(&(&1.type == :page)) == []
    end

    test "kinds narrows to the named lanes" do
      admin = user(:admin)
      page = CMS.create_page!(%{title: "Live", slug: slug()}, actor: admin)
      page = CMS.publish_page!(page, %{}, actor: admin)
      page = CMS.update_page!(page, %{unpublish_at: in_days(5)}, actor: admin)

      assert kinds_for(events(admin, %{kinds: [:unpublish]}), page.id) == [:unpublish]
    end

    test "health narrows to content, excluding the lanes that have none" do
      admin = user(:admin)

      stale =
        CMS.create_page!(%{title: "Stale", slug: slug(), review_after_days: 5}, actor: admin)

      stale = CMS.publish_page!(stale, %{}, actor: admin)

      stale
      |> Ash.Changeset.for_update(:backdate_published_at, %{published_at: in_days(-20)})
      |> Ash.update!(authorize?: false)

      release =
        CMS.create_release!(%{name: "Launch"}, actor: admin)
        |> CMS.schedule_release!(%{scheduled_at: in_days(6)}, actor: admin)

      filtered = events(admin, %{health: [:overdue]})
      ids = Enum.map(filtered, & &1.id)

      assert stale.id in ids
      refute release.id in ids, "a health filter is a question about content"
      assert Enum.all?(filtered, &(&1.health == :overdue))
    end
  end

  describe "authorization" do
    test "runs as the actor — a viewer sees published content, not drafts" do
      admin = user(:admin)
      viewer = user(:viewer)

      draft =
        CMS.create_page!(%{title: "Secret", slug: slug(), scheduled_at: in_days(2)},
          actor: admin
        )

      live = CMS.create_page!(%{title: "Public", slug: slug()}, actor: admin)
      live = CMS.publish_page!(live, %{}, actor: admin)

      ids = events(viewer) |> Enum.map(& &1.id)
      refute draft.id in ids
      assert live.id in ids
    end
  end

  describe "grouping" do
    test "events_by_day keys on the event's own date" do
      admin = user(:admin)
      at = in_days(3)

      page = CMS.create_page!(%{title: "Grouped", slug: slug(), scheduled_at: at}, actor: admin)

      {from, to} = window()
      grouped = KilnCMS.CMS.Calendar.events_by_day(admin, org(), from, to)

      assert Enum.any?(grouped[DateTime.to_date(at)] || [], &(&1.id == page.id))
    end
  end

  describe "dynamic types" do
    test "entries plot alongside compiled types" do
      admin = user(:admin)

      definition =
        CMS.create_type_definition!(
          %{name: "cal#{System.unique_integer([:positive])}", label: "Cal"},
          actor: admin
        )

      entry =
        ContentTypes.create!(
          definition.name,
          %{title: "Dyn", slug: slug(), scheduled_at: in_days(2)},
          actor: admin
        )

      assert kinds_for(events(admin), entry.id) == [:publish]
    end
  end
end
