defmodule KilnCMS.Notifications.SystemActorAuthorizationTest do
  @moduledoc """
  #1659 batch 4: the notifier and Web Push run as scoped system actors
  (`KilnCMS.Notifications.system/0`, `KilnCMS.Push.system/0`) rather than
  `authorize?: false`.

  Every grant is paired with a refusal, and every migrated read that decides
  "who hears about this" or "was this already fired" is tested with the grant
  taken away (`with_actor(nil, ...)`): it must fail CLOSED, raising or
  returning an error, never filtering to `[]`, which is how a refused read
  answers and how a silently dropped notification looks. Reads assert on the
  row being there, never on `{:ok, _}`.
  """
  # async: false — configures the global VAPID keys.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.TaskDigestWorker
  alias KilnCMS.Push
  alias KilnCMS.Push.Vapid
  alias KilnCMS.Push.Worker

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Push, [])
    {public, private} = Vapid.generate()

    Application.put_env(
      :kiln_cms,
      KilnCMS.Push,
      Keyword.merge(original,
        vapid_public_key: public,
        vapid_private_key: private,
        vapid_subject: "mailto:ops@example.com"
      )
    )

    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Push, original) end)
    :ok
  end

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sab4-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role,
      name: "Ada"
    })
  end

  defp overdue_task do
    editor = user(:editor)
    assignee = user(:editor)

    {:ok, task} =
      CMS.assign_task(
        %{
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          assignee_id: assignee.id,
          due_on: Date.add(today(), -1)
        },
        actor: editor
      )

    KilnCMS.DataCase.drain_oban()
    task
  end

  defp tenant, do: Accounts.default_org_id()

  describe "CMS.Task — the digest's reads and its overdue stamp" do
    test "the system actor reads the digest's two queries" do
      task = overdue_task()
      system = Notifications.system()

      due =
        CMS.list_tasks_due_within!(Date.add(today(), 3),
          actor: system,
          authorize_with: :error,
          tenant: tenant()
        )

      overdue =
        CMS.list_newly_overdue_tasks!(actor: system, authorize_with: :error, tenant: tenant())

      assert task.id in Enum.map(due, & &1.id)
      assert task.id in Enum.map(overdue, & &1.id)
    end

    test "the system actor may stamp a task as overdue-notified" do
      task = overdue_task()

      assert {:ok, stamped} =
               CMS.mark_task_overdue_notified(task, %{},
                 actor: Notifications.system(),
                 tenant: tenant()
               )

      refute is_nil(stamped.overdue_notified_on)
    end

    test "the stamp is a claim: a second run's stamp of the same task is refused" do
      task = overdue_task()
      system = Notifications.system()

      # Both runs read the task before either stamped it.
      assert {:ok, _} = CMS.mark_task_overdue_notified(task, %{}, actor: system, tenant: tenant())

      assert {:error, _} =
               CMS.mark_task_overdue_notified(task, %{}, actor: system, tenant: tenant())
    end

    test "…and no other update: it cannot complete, reopen or edit a task" do
      task = overdue_task()
      system = Notifications.system()

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.complete_task(task, %{}, actor: system, tenant: tenant())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.reopen_task(task, %{}, actor: system, tenant: tenant())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_task(task, %{note: "rewritten"}, actor: system, tenant: tenant())
    end

    test "with the grant gone, the digest fails the job instead of finding nothing to do" do
      _task = overdue_task()

      log =
        capture_log(fn ->
          assert_raise RuntimeError, ~r/task digest failed for orgs/, fn ->
            Notifications.with_actor(nil, fn ->
              TaskDigestWorker.perform(%Oban.Job{args: %{}})
            end)
          end
        end)

      assert log =~ "Forbidden"
    end

    # Each read on its own: run in order, the first raise would hide a second
    # read that had gone back to filtering to `[]`.
    test "with the grant gone, the due-soon read raises rather than reading \"nothing due\"" do
      _task = overdue_task()

      assert_raise Ash.Error.Forbidden, fn ->
        Notifications.with_actor(nil, fn ->
          TaskDigestWorker.send_digests(tenant(), Date.add(today(), 3))
        end)
      end
    end

    test "with the grant gone, the newly-overdue read raises rather than firing nothing" do
      _task = overdue_task()

      assert_raise Ash.Error.Forbidden, fn ->
        Notifications.with_actor(nil, fn ->
          TaskDigestWorker.fire_overdue_events(tenant())
        end)
      end
    end
  end

  describe "CMS.Comment — a thread's participants" do
    defp page(author) do
      CMS.create_page!(
        %{title: "Discussed", slug: "sab4-#{System.unique_integer([:positive])}"},
        actor: author
      )
    end

    defp comment(page, block_id, body, actor) do
      CMS.add_comment!(
        %{content_type: "page", content_id: page.id, block_id: block_id, body: body},
        actor: actor
      )
    end

    test "a participant on the thread hears about the next comment" do
      author = user(:editor)
      participant = user(:editor)
      commenter = user(:editor)
      page = page(author)
      block_id = Ecto.UUID.generate()

      comment(page, block_id, "First thought", participant)
      KilnCMS.DataCase.drain_oban()
      comment(page, block_id, "Second thought", commenter)
      KilnCMS.DataCase.drain_oban()

      events =
        participant.id
        |> Notifications.notifications_for_user!(actor: participant)
        |> Enum.map(& &1.excerpt)

      # Reached only through the thread read: the participant is not the
      # author and is not mentioned.
      assert "Second thought" in events
    end

    test "with the grant gone, the thread read raises rather than notifying nobody" do
      author = user(:editor)
      commenter = user(:editor)
      page = page(author)
      block_id = Ecto.UUID.generate()

      added = comment(page, block_id, "Anyone?", commenter)
      KilnCMS.DataCase.drain_oban()

      assert_raise Ash.Error.Forbidden, fn ->
        Notifications.with_actor(nil, fn ->
          Notifications.dispatch_comment(:comment_added, added, page, commenter)
        end)
      end
    end
  end

  describe "Accounts.PushSubscription" do
    defp params(endpoint \\ nil) do
      {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)

      %{
        "endpoint" =>
          endpoint || "https://push.example.com/x/#{System.unique_integer([:positive])}",
        "p256dh" => Base.url_encode64(public, padding: false),
        "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        "label" => "Phone"
      }
    end

    defp device(user) do
      {:ok, subscription} = Push.subscribe(params(), user, nil)
      subscription
    end

    defp job(subscription) do
      %Oban.Job{args: %{"subscription_id" => subscription.id, "payload" => %{"title" => "t"}}}
    end

    defp reload(subscription),
      do: Accounts.get_push_subscription!(subscription.id, authorize?: false)

    defp stub(status),
      do: Req.Test.stub(KilnCMS.Push, fn conn -> Plug.Conn.send_resp(conn, status, "") end)

    defp raw(user_id) do
      p = params()

      %{
        user_id: user_id,
        endpoint: p["endpoint"],
        p256dh: p["p256dh"],
        auth: p["auth"],
        label: "Phone"
      }
    end

    test "a user subscribes their own device" do
      me = user(:editor)
      assert device(me).user_id == me.id
    end

    test "…but not a device for somebody else" do
      me = user(:editor)
      them = user(:editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.subscribe_to_push(raw(them.id), actor: me)
    end

    test "the system actor cannot subscribe anybody" do
      them = user(:editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.subscribe_to_push(raw(them.id), actor: Push.system())
    end

    test "the system actor reads a user's devices for sending, and by id for the worker" do
      reviewer = user(:editor)
      subscription = device(reviewer)
      system = Push.system()

      assert {:ok, found} =
               Accounts.push_subscriptions_for([reviewer.id],
                 actor: system,
                 authorize_with: :error
               )

      assert subscription.id in Enum.map(found, & &1.id)

      assert {:ok, %{id: id}} =
               Accounts.get_push_subscription(subscription.id,
                 actor: system,
                 authorize_with: :error
               )

      assert id == subscription.id
    end

    test "the system actor is refused the settings list and the key-rotation sweep" do
      reviewer = user(:editor)
      _subscription = device(reviewer)
      system = Push.system()

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.list_push_subscriptions(reviewer.id,
                 actor: system,
                 authorize_with: :error
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.push_subscriptions_bound_to_key(Ecto.UUID.generate(), "key",
                 actor: system,
                 authorize_with: :error
               )
    end

    test "a person is refused the sender's read and the worker's bookkeeping" do
      reviewer = user(:editor)
      subscription = device(reviewer)

      # A read refused in filter mode would come back `{:ok, []}` — ask for
      # the error so the assertion is about the grant, not an empty result.
      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.push_subscriptions_for([reviewer.id],
                 actor: reviewer,
                 authorize_with: :error
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.touch_push_subscription(subscription, actor: reviewer)
    end

    test "notify/2 enqueues one delivery per device the sender can read" do
      reviewer = user(:editor)
      subscription = device(reviewer)

      assert :ok = Push.notify([reviewer], %{"title" => "t"})

      assert [job] = all_enqueued(worker: Worker)
      assert job.args["subscription_id"] == subscription.id
    end

    test "with the grant gone, notify/2 logs the refusal rather than dropping pushes silently" do
      reviewer = user(:editor)
      _subscription = device(reviewer)

      log =
        capture_log(fn ->
          assert :ok =
                   Push.with_actor(nil, fn -> Push.notify([reviewer], %{"title" => "t"}) end)
        end)

      assert log =~ "Push notifications not sent"
      assert all_enqueued(worker: Worker) == []
    end

    test "a delivered push is stamped, as the system actor" do
      stub(201)
      subscription = device(user(:editor))

      assert :ok = Worker.perform(job(subscription))
      refute is_nil(reload(subscription).last_delivered_at)
    end

    test "a device the push service reports gone is pruned, as the system actor" do
      stub(410)
      subscription = device(user(:editor))

      capture_log(fn -> assert :ok = Worker.perform(job(subscription)) end)

      assert {:ok, nil} =
               Accounts.get_push_subscription(subscription.id,
                 authorize?: false,
                 not_found_error?: false
               )
    end

    test "with the grant gone, the worker errors (and retries) rather than dropping the push" do
      stub(201)
      subscription = device(user(:editor))

      assert {:error, %Ash.Error.Forbidden{}} =
               Push.with_actor(nil, fn -> Worker.perform(job(subscription)) end)

      assert is_nil(reload(subscription).last_delivered_at)
    end
  end

  test "with_actor/2 restores the real actor afterwards, even when the block raises" do
    assert_raise RuntimeError, fn -> Notifications.with_actor(nil, fn -> raise "boom" end) end
    assert %KilnCMS.SystemActor{subsystem: :notifications} = Notifications.system()

    assert_raise RuntimeError, fn -> Push.with_actor(nil, fn -> raise "boom" end) end
    assert %KilnCMS.SystemActor{subsystem: :push} = Push.system()
  end
end
