defmodule KilnCMS.CMS.ScheduledPublishingTest do
  @moduledoc """
  The AshOban `publish_scheduled` trigger publishes draft content once its
  `scheduled_at` has passed, and leaves future-scheduled content alone.
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
