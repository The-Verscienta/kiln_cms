defmodule KilnCMS.CMS.ScheduledPublishingTest do
  @moduledoc """
  The AshOban `publish_scheduled` trigger publishes draft content once its
  `scheduled_at` has passed (and leaves future-scheduled content alone);
  the `unpublish_scheduled` trigger takes published content back down once
  its `unpublish_at` passes (the embargo end).
  """
  # Oban runs in :manual mode; `schedule_and_run_triggers/2` drains the queue
  # inline in this process, so the test's own sandbox connection is used and we
  # can stay async (and isolated from other tests' content).
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sched-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp draft_page(scheduled_at, admin) do
    CMS.create_page!(
      %{
        title: "Scheduled",
        slug: "sched-#{System.unique_integer([:positive])}",
        scheduled_at: scheduled_at
      },
      actor: admin
    )
  end

  test "publishes a page whose scheduled_at has passed" do
    admin = admin()
    past = DateTime.add(DateTime.utc_now(), -60, :second)
    page = draft_page(past, admin)
    assert page.state == :draft

    AshOban.schedule_and_run_triggers(KilnCMS.CMS.Page,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )

    reloaded = CMS.get_page!(page.id, actor: admin)
    assert reloaded.state == :published
    assert reloaded.published_at
    assert is_nil(reloaded.scheduled_at)
  end

  test "leaves a future-scheduled page as a draft" do
    admin = admin()
    future = DateTime.add(DateTime.utc_now(), 3600, :second)
    page = draft_page(future, admin)

    AshOban.schedule_and_run_triggers(KilnCMS.CMS.Page,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )

    reloaded = CMS.get_page!(page.id, actor: admin)
    assert reloaded.state == :draft
    assert reloaded.scheduled_at
  end

  defp published_page(admin, attrs \\ %{}) do
    page =
      CMS.create_page!(
        Map.merge(
          %{title: "Live", slug: "sched-#{System.unique_integer([:positive])}"},
          attrs
        ),
        actor: admin
      )

    CMS.publish_page!(page, %{}, actor: admin)
  end

  test "unpublishes a page whose unpublish_at has passed" do
    admin = admin()
    page = published_page(admin)

    # Set the embargo end in the past (updates are allowed on published rows).
    page =
      CMS.update_page!(
        page,
        %{unpublish_at: DateTime.add(DateTime.utc_now(), -60, :second)},
        actor: admin
      )

    assert page.state == :published

    AshOban.schedule_and_run_triggers(KilnCMS.CMS.Page,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )

    reloaded = CMS.get_page!(page.id, actor: admin)
    assert reloaded.state == :draft
    assert is_nil(reloaded.unpublish_at)
    assert is_nil(reloaded.published_version_id)
  end

  test "leaves published content with a future unpublish_at alone" do
    admin = admin()
    page = published_page(admin)

    page =
      CMS.update_page!(
        page,
        %{unpublish_at: DateTime.add(DateTime.utc_now(), 3600, :second)},
        actor: admin
      )

    AshOban.schedule_and_run_triggers(KilnCMS.CMS.Page,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )

    reloaded = CMS.get_page!(page.id, actor: admin)
    assert reloaded.state == :published
    assert reloaded.unpublish_at
  end

  test "an embargo end before the scheduled publish is rejected" do
    admin = admin()
    now = DateTime.utc_now()

    assert {:error, error} =
             CMS.create_page(
               %{
                 title: "Backwards",
                 slug: "sched-#{System.unique_integer([:positive])}",
                 scheduled_at: DateTime.add(now, 7200, :second),
                 unpublish_at: DateTime.add(now, 3600, :second)
               },
               actor: admin
             )

    assert Exception.message(error) =~ "must be after the scheduled publish time"
  end

  test "the scheduled publish is authorized as a system job (no actor needed)" do
    admin = admin()
    past = DateTime.add(DateTime.utc_now(), -60, :second)
    page = draft_page(past, admin)

    # Runs with no actor — succeeds only because of the AshObanInteraction bypass.
    AshOban.schedule_and_run_triggers(KilnCMS.CMS.Page,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )

    assert CMS.get_page!(page.id, authorize?: false).state == :published
  end
end
