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
  use Oban.Testing, repo: KilnCMS.Repo

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

  # #2746. The worker reads the due record, then runs the scheduled action on
  # that struct: the checkpoint, the gates and the derived columns all sit
  # between the read and the UPDATE. A write landing in that window used to be
  # overwritten. `race/3` puts an editor's write exactly there: the action's
  # telemetry span starts after the worker's read and before any of its hooks.
  describe "a write between the worker's read and its UPDATE" do
    test "an archive is not undone by the scheduled publish, and nothing fires" do
      admin = admin()
      page = draft_page(DateTime.add(DateTime.utc_now(), -60, :second), admin)
      endpoint!(admin, ["page.published"])

      results =
        race(:publish_scheduled, KilnCMS.CMS.Page, fn ->
          page.id |> CMS.get_page!(actor: admin) |> CMS.archive_page!(actor: admin)
        end)

      assert %{cancelled: 1, failure: 0} = results
      reloaded = CMS.get_page!(page.id, actor: admin)
      assert reloaded.state == :archived
      assert is_nil(reloaded.published_at)
      refute_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => page.id})
      refute_enqueued(worker: KilnCMS.Webhooks.DeliveryWorker)
    end

    test "a publish by hand is not published a second time" do
      admin = admin()
      page = draft_page(DateTime.add(DateTime.utc_now(), -60, :second), admin)
      endpoint!(admin, ["page.published"])

      results =
        race(:publish_scheduled, KilnCMS.CMS.Page, fn ->
          page.id |> CMS.get_page!(actor: admin) |> CMS.publish_page!(actor: admin)
        end)

      assert %{cancelled: 1, failure: 0} = results
      reloaded = CMS.get_page!(page.id, actor: admin)
      assert reloaded.state == :published
      # The hand publish's one delivery, and no duplicate from the scheduler.
      assert [_one] = all_enqueued(worker: KilnCMS.Webhooks.DeliveryWorker)
    end

    test "a reschedule keeps its new date and does not publish" do
      admin = admin()
      page = draft_page(DateTime.add(DateTime.utc_now(), -60, :second), admin)
      tomorrow = DateTime.add(DateTime.utc_now(), 1, :day)

      race(:publish_scheduled, KilnCMS.CMS.Page, fn ->
        page.id
        |> CMS.get_page!(actor: admin)
        |> CMS.update_page!(%{scheduled_at: tomorrow}, actor: admin)
      end)

      reloaded = CMS.get_page!(page.id, actor: admin)
      assert reloaded.state == :draft
      assert DateTime.compare(reloaded.scheduled_at, tomorrow) == :eq
    end

    test "an archive is not turned back into a draft by the embargo end" do
      admin = admin()
      page = expiring_page(admin, :unpublish)
      endpoint!(admin, ["page.unpublished"])

      results =
        race(:unpublish_scheduled, KilnCMS.CMS.Page, fn ->
          page.id |> CMS.get_page!(actor: admin) |> CMS.archive_page!(actor: admin)
        end)

      assert %{cancelled: 1, failure: 0} = results
      assert CMS.get_page!(page.id, actor: admin).state == :archived
      # The archive's own withdrawal, and none from the embargo end.
      assert [_one] = all_enqueued(worker: KilnCMS.Webhooks.DeliveryWorker)
    end

    test "an extended embargo end keeps the record live and the new date" do
      admin = admin()
      page = expiring_page(admin, :unpublish)
      endpoint!(admin, ["page.unpublished"])
      tomorrow = DateTime.add(DateTime.utc_now(), 1, :day)

      race(:unpublish_scheduled, KilnCMS.CMS.Page, fn ->
        page.id
        |> CMS.get_page!(actor: admin)
        |> CMS.update_page!(%{unpublish_at: tomorrow}, actor: admin)
      end)

      reloaded = CMS.get_page!(page.id, actor: admin)
      assert reloaded.state == :published
      assert reloaded.published_version_id
      assert DateTime.compare(reloaded.unpublish_at, tomorrow) == :eq
      refute_enqueued(worker: KilnCMS.Webhooks.DeliveryWorker)
    end

    test "an expiry action switched to :flag keeps the record live and its date" do
      admin = admin()
      page = expiring_page(admin, :unpublish)

      race(:unpublish_scheduled, KilnCMS.CMS.Page, fn ->
        page.id
        |> CMS.get_page!(actor: admin)
        |> CMS.update_page!(%{expiry_action: :flag}, actor: admin)
      end)

      reloaded = CMS.get_page!(page.id, actor: admin)
      assert reloaded.state == :published
      assert reloaded.expiry_action == :flag
      # The passed date is the `:expired` signal a flag exists to keep.
      assert DateTime.compare(reloaded.unpublish_at, page.unpublish_at) == :eq
    end

    test "an unpublish by hand is not archived by the embargo end" do
      admin = admin()
      page = expiring_page(admin, :archive)
      endpoint!(admin, ["page.archived"])

      results =
        race(:archive_scheduled, KilnCMS.CMS.Page, fn ->
          page.id |> CMS.get_page!(actor: admin) |> CMS.unpublish_page!(actor: admin)
        end)

      assert %{cancelled: 1, failure: 0} = results
      assert CMS.get_page!(page.id, actor: admin).state == :draft
      refute_enqueued(worker: KilnCMS.Webhooks.DeliveryWorker)
    end

    test "an expiry action switched to :unpublish is not archived" do
      admin = admin()
      page = expiring_page(admin, :archive)

      race(:archive_scheduled, KilnCMS.CMS.Page, fn ->
        page.id
        |> CMS.get_page!(actor: admin)
        |> CMS.update_page!(%{expiry_action: :unpublish}, actor: admin)
      end)

      reloaded = CMS.get_page!(page.id, actor: admin)
      assert reloaded.state == :published
      assert reloaded.expiry_action == :unpublish
    end

    # What the worker's cancel rests on: AshOban maps exactly this shape, one
    # `StaleRecord` and nothing else, to `{:cancel, :trigger_no_longer_applies}`.
    # Any other error is raised and retried.
    test "the refusal is a lone StaleRecord" do
      admin = admin()
      held = draft_page(DateTime.add(DateTime.utc_now(), -60, :second), admin)
      CMS.archive_page!(held, actor: admin)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               CMS.publish_scheduled_page(held, %{}, authorize?: false)
    end
  end

  # A published page whose embargo end passed a minute ago.
  defp expiring_page(admin, expiry_action) do
    admin
    |> published_page()
    |> CMS.update_page!(
      %{
        unpublish_at: DateTime.add(DateTime.utc_now(), -60, :second),
        expiry_action: expiry_action
      },
      actor: admin
    )
  end

  defp endpoint!(admin, events),
    do:
      CMS.create_webhook_endpoint!(%{url: "https://example.test/hook", events: events},
        actor: admin
      )

  # Runs `trigger`'s scheduler and worker inline, with `interleave` called once
  # between the worker's read of the record and its write.
  defp race(trigger, resource, interleave) do
    id = "race-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        id,
        [:ash, Ash.Domain.Info.short_name(CMS), :update, :start],
        &__MODULE__.interleave/4,
        %{pid: self(), action: trigger, interleave: interleave, id: id}
      )

    try do
      AshOban.schedule_and_run_triggers({resource, trigger},
        drain_queues?: true,
        with_recursion: true,
        with_scheduled: true
      )
    after
      :telemetry.detach(id)
    end
  end

  @doc false
  # Telemetry handlers are global, so this one acts only in the test's own
  # process (the drain runs the worker inline) and only once.
  def interleave(_event, _measurements, %{action: action}, %{action: action} = config) do
    if self() == config.pid and not Process.get(config.id, false) do
      Process.put(config.id, true)
      config.interleave.()
    end
  end

  def interleave(_event, _measurements, _metadata, _config), do: :ok
end
