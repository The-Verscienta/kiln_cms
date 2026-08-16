defmodule KilnCMS.CMS.HealthSweepTest do
  @moduledoc """
  The freshness sweep and the remediation loop it feeds
  (`docs/content-lifecycles.md`): overdue content raises an automation event,
  and a `:create_task` rule turns that into one task — one, however many days
  the content stays overdue.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Automation
  alias KilnCMS.CMS
  alias KilnCMS.CMS.HealthSweep

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sweep-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "sweep-#{System.unique_integer([:positive])}"
  defp org_id, do: KilnCMS.Accounts.default_org_id()

  # Published under a cadence, then backdated past it — the shape of every piece
  # of content this feature exists for.
  defp overdue_page(admin, opts \\ []) do
    days = Keyword.get(opts, :days, 5)
    ago = Keyword.get(opts, :published_days_ago, 40)

    page =
      CMS.create_page!(
        %{
          title: "Monograph #{System.unique_integer([:positive])}",
          slug: slug(),
          review_after_days: days
        },
        actor: admin
      )

    page = CMS.publish_page!(page, %{}, actor: admin)

    page
    |> Ash.Changeset.for_update(:backdate_published_at, %{
      published_at: DateTime.add(DateTime.utc_now(), -ago * 86_400, :second)
    })
    |> Ash.update!(authorize?: false)
  end

  defp task_rule!(admin, config \\ %{}) do
    Automation.create_rule!(
      %{
        name: "Review due → task",
        trigger_event: :health_overdue,
        content_type: "page",
        action: :create_task,
        config: config,
        enabled: true
      },
      actor: admin
    )
  end

  # The sweep enqueues; Oban is :manual in tests, so drain to the reaction.
  defp sweep_and_drain! do
    HealthSweep.run_org(org_id())
    Oban.drain_queue(queue: :default, with_recursion: true, with_scheduled: true)
  end

  defp lifecycle_tasks(content_id, admin) do
    CMS.list_open_tasks_of_kind!("page", content_id, :lifecycle_review, actor: admin)
  end

  describe "the sweep" do
    test "dispatches an event for overdue content and none for fresh" do
      admin = user(:admin)
      stale = overdue_page(admin)

      fresh =
        CMS.create_page!(%{title: "Current", slug: slug(), review_after_days: 365}, actor: admin)

      fresh = CMS.publish_page!(fresh, %{}, actor: admin)

      task_rule!(admin)
      sweep_and_drain!()

      assert [_task] = lifecycle_tasks(stale.id, admin)
      assert [] = lifecycle_tasks(fresh.id, admin)
    end

    test "content with no cadence is never swept, however old" do
      admin = user(:admin)

      ancient = CMS.create_page!(%{title: "Timeless", slug: slug()}, actor: admin)
      ancient = CMS.publish_page!(ancient, %{}, actor: admin)

      ancient
      |> Ash.Changeset.for_update(:backdate_published_at, %{
        published_at: DateTime.add(DateTime.utc_now(), -3000 * 86_400, :second)
      })
      |> Ash.update!(authorize?: false)

      task_rule!(admin)
      sweep_and_drain!()

      assert [] = lifecycle_tasks(ancient.id, admin)
    end

    test "a flagged expiry raises the expired trigger, not the overdue one" do
      admin = user(:admin)

      page =
        CMS.create_page!(%{title: "Notice", slug: slug(), expiry_action: :flag}, actor: admin)

      page = CMS.publish_page!(page, %{}, actor: admin)

      page =
        CMS.update_page!(
          page,
          %{unpublish_at: DateTime.add(DateTime.utc_now(), -86_400, :second)},
          actor: admin
        )

      # A rule on :health_overdue must NOT catch an expiry.
      task_rule!(admin)
      sweep_and_drain!()
      assert [] = lifecycle_tasks(page.id, admin)

      Automation.create_rule!(
        %{
          name: "Expired → task",
          trigger_event: :health_expired,
          content_type: "page",
          action: :create_task,
          config: %{},
          enabled: true
        },
        actor: admin
      )

      sweep_and_drain!()
      assert [_task] = lifecycle_tasks(page.id, admin)
    end

    test "emits telemetry with the counts by health" do
      admin = user(:admin)
      overdue_page(admin)

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "health-sweep-#{inspect(ref)}",
        [:kiln_cms, :lifecycle, :health_sweep],
        fn _event, measurements, metadata, _ -> send(parent, {ref, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("health-sweep-#{inspect(ref)}") end)

      HealthSweep.run_org(org_id())

      assert_receive {^ref, measurements, metadata}
      assert measurements.overdue >= 1
      assert Map.has_key?(measurements, :expired)
      assert metadata.org_id == org_id()
    end
  end

  describe "the :create_task reaction" do
    test "creates exactly one task however many times the sweep runs" do
      admin = user(:admin)
      stale = overdue_page(admin)
      task_rule!(admin)

      # Three days of an unattended overdue record.
      sweep_and_drain!()
      sweep_and_drain!()
      sweep_and_drain!()

      assert [task] = lifecycle_tasks(stale.id, admin)
      assert task.kind == :lifecycle_review
      # A review is not finished by republishing the same stale document.
      refute task.auto_complete_on_publish
    end

    test "raises a fresh task once the previous one is done" do
      admin = user(:admin)
      stale = overdue_page(admin)
      task_rule!(admin)

      sweep_and_drain!()
      assert [task] = lifecycle_tasks(stale.id, admin)

      CMS.complete_task!(task, actor: admin)
      assert [] = lifecycle_tasks(stale.id, admin)

      # Still overdue — nobody actually re-read it — so the next sweep asks again.
      sweep_and_drain!()
      assert [second] = lifecycle_tasks(stale.id, admin)
      assert second.id != task.id
    end

    test "assigns to the content's author when they are still an editor" do
      admin = user(:admin)
      author = user(:editor)

      stale = overdue_page(admin)

      stale
      |> Ash.Changeset.for_update(:reassign_author, %{author_id: author.id})
      |> Ash.update!(authorize?: false)

      task_rule!(admin)
      sweep_and_drain!()

      assert [task] = lifecycle_tasks(stale.id, admin)
      assert task.assignee_id == author.id
    end

    test "falls back to the rule's assignee when the author cannot hold a task" do
      admin = user(:admin)
      viewer = user(:viewer)
      fallback = user(:editor)

      stale = overdue_page(admin)

      # An author who has since been demoted — `AssigneeIsEditor` would refuse
      # them, so the rule's configured assignee carries it instead.
      stale
      |> Ash.Changeset.for_update(:reassign_author, %{author_id: viewer.id})
      |> Ash.update!(authorize?: false)

      task_rule!(admin, %{"assignee_id" => fallback.id})
      sweep_and_drain!()

      assert [task] = lifecycle_tasks(stale.id, admin)
      assert task.assignee_id == fallback.id
    end

    test "creates nothing, and does not crash, when no assignee can be found" do
      admin = user(:admin)
      viewer = user(:viewer)
      stale = overdue_page(admin)

      stale
      |> Ash.Changeset.for_update(:reassign_author, %{author_id: viewer.id})
      |> Ash.update!(authorize?: false)

      # No fallback configured and an ineligible author: the reaction has
      # nowhere to route the work, and a scheduled job must not die over it.
      task_rule!(admin)
      capture_log(fn -> sweep_and_drain!() end)

      assert [] = lifecycle_tasks(stale.id, admin)
    end

    test "honours the rule's due window and note template" do
      admin = user(:admin)
      stale = overdue_page(admin)
      task_rule!(admin, %{"due_in_days" => 3, "note" => "Re-read {{title}} please"})

      sweep_and_drain!()

      assert [task] = lifecycle_tasks(stale.id, admin)
      assert task.due_on == Date.add(Date.utc_today(), 3)
      assert task.note =~ stale.title
    end

    test "clamps an out-of-range due window rather than trusting it" do
      admin = user(:admin)
      stale = overdue_page(admin)

      # Seeded past the config validation, which refuses this at the form. The
      # worker must not trust stored config regardless: a rule can predate a
      # validation, or arrive from a seed.
      Ash.Seed.seed!(KilnCMS.Automation.Rule, %{
        name: "Bad window",
        trigger_event: :health_overdue,
        content_type: "page",
        action: :create_task,
        config: %{"due_in_days" => 99_999},
        enabled: true,
        org_id: org_id()
      })

      sweep_and_drain!()

      assert [task] = lifecycle_tasks(stale.id, admin)
      assert task.due_on == Date.add(Date.utc_today(), 7)
    end

    test "a disabled rule does nothing" do
      admin = user(:admin)
      stale = overdue_page(admin)

      admin |> task_rule!() |> Automation.update_rule!(%{enabled: false}, actor: admin)
      sweep_and_drain!()

      assert [] = lifecycle_tasks(stale.id, admin)
    end
  end

  describe "marking reviewed closes the loop" do
    test "an attested record stops raising events" do
      admin = user(:admin)
      stale = overdue_page(admin)
      task_rule!(admin)

      sweep_and_drain!()
      assert [task] = lifecycle_tasks(stale.id, admin)

      # The human does the thing the task asked for.
      CMS.mark_page_reviewed!(stale, %{}, actor: admin)
      CMS.complete_task!(task, actor: admin)

      sweep_and_drain!()
      assert [] = lifecycle_tasks(stale.id, admin)
    end
  end
end
