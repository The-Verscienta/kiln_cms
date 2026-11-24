defmodule KilnCMS.Billing.WebhookSweeperTest do
  @moduledoc """
  The sweeper for provider webhook events nothing will process (#3159):
  `KilnCMS.Billing.WebhookEvent`'s `:redrive` and `:give_up` triggers.

  Three windows leave an acknowledged event without a job, and the provider
  will not redeliver it:

    * A: a `:received` row with no job (recorded before enqueue became atomic,
      or its job was lost);
    * B: a `:failed` row whose job used its `max_attempts`;
    * C: a `:processing` row whose settle stamp did not save, or whose worker
      died, past the takeover.

  Each window has a test that it is redriven and tests that a row which only
  looks like it (too young, a job that will still run) is left alone. Then
  the bound: three redrives, then give-up; and the age bound, so an event
  older than the provider's retry window is given up on, never replayed.

  The triggers run on `:billing_sweeper`. `AshOban.schedule_and_run_triggers/2`
  drains only the queues of the triggers it runs, so the `:billing` job a
  redrive inserts stays in the queue for the test to look at until it drains
  it.

  `async: false`: one test sets `:billing_webhook_insert`, the enqueue seam,
  and the replayed-checkout tests select the provider double, both of which
  are application env.
  """
  use KilnCMS.DataCase, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.WebhookEvent
  alias KilnCMS.Billing.WebhookWorker
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())
  @live_states ~w(available scheduled retryable executing suspended)
  @oban_context %{private: %{ash_oban?: true}}

  defp uniq, do: System.unique_integer([:positive])
  defp org_id, do: Accounts.default_org_id()
  defp minutes_ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

  # A row as the receiver or worker would have left it, with no job: seeded,
  # because `:receive` always inserts one.
  defp event_row(attrs \\ %{}) do
    at = Map.get(attrs, :at, minutes_ago(60))

    Ash.Seed.seed!(
      WebhookEvent,
      Map.merge(
        %{
          provider: :stripe,
          provider_event_id: "evt_#{uniq()}",
          type: "ping",
          payload: %{"type" => "ping"},
          status: :received,
          redrive_count: 0,
          inserted_at: at,
          updated_at: at
        },
        Map.delete(attrs, :at)
      )
    )
  end

  defp reload(row), do: Billing.get_webhook_event!(row.id, actor: Billing.system())

  defp sweep do
    AshOban.schedule_and_run_triggers(WebhookEvent,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )
  end

  defp jobs_for(row) do
    Repo.all(
      from(j in Oban.Job,
        where:
          j.worker == "KilnCMS.Billing.WebhookWorker" and
            fragment("?->>'webhook_event_id' = ?", j.args, ^row.id),
        order_by: j.id
      )
    )
  end

  defp job_in_state(row, state) do
    {:ok, job} = WebhookWorker.enqueue(row)
    {1, _} = Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
    job
  end

  # A job that used its last attempt: Oban keeps it, `discarded`.
  defp exhaust_jobs(row) do
    Repo.update_all(
      from(j in Oban.Job,
        where:
          j.worker == "KilnCMS.Billing.WebhookWorker" and
            fragment("?->>'webhook_event_id' = ?", j.args, ^row.id)
      ),
      set: [state: "discarded"]
    )
  end

  defp assert_redriven(row, count \\ 1) do
    reloaded = reload(row)
    assert reloaded.redrive_count == count
    assert is_nil(reloaded.gave_up_at)
    assert Enum.count(jobs_for(row), &(&1.state == "available")) == 1
    reloaded
  end

  defp assert_untouched(row, jobs_before \\ 0) do
    reloaded = reload(row)
    assert reloaded.redrive_count == row.redrive_count
    assert reloaded.status == row.status
    assert is_nil(reloaded.gave_up_at)
    assert length(jobs_for(row)) == jobs_before
    reloaded
  end

  defp attach_gave_up do
    ref = make_ref()
    test = self()

    :telemetry.attach(
      "webhook-sweeper-#{inspect(ref)}",
      [:kiln_cms, :billing, :webhook_event, :gave_up],
      fn _event, measurements, metadata, _config ->
        send(test, {:gave_up, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("webhook-sweeper-#{inspect(ref)}") end)
  end

  describe "window A: a :received row" do
    test "with no job, past the grace period, is re-enqueued" do
      row = event_row(%{at: minutes_ago(WebhookEvent.received_grace_minutes() + 1)})

      sweep()

      assert %{status: :received} = assert_redriven(row)
    end

    test "younger than the grace period is left to its own job" do
      row = event_row(%{at: minutes_ago(WebhookEvent.received_grace_minutes() - 2)})

      sweep()

      assert_untouched(row)
    end

    test "with a job that will run, or is running, is left alone" do
      for state <- @live_states do
        row = event_row()
        job_in_state(row, state)

        sweep()

        assert_untouched(row, 1)
      end
    end
  end

  describe "window B: a :failed row" do
    test "whose job used its attempts is re-enqueued" do
      row = event_row(%{status: :failed})
      job_in_state(row, "discarded")

      sweep()

      assert %{status: :failed} = assert_redriven(row)
    end

    test "with a job that will retry it is left alone" do
      for state <- @live_states do
        row = event_row(%{status: :failed})
        job_in_state(row, state)

        sweep()

        assert_untouched(row, 1)
      end
    end
  end

  describe "window C: a :processing row" do
    test "past the takeover with no job is released to :failed, re-enqueued and then settled" do
      row = event_row(%{status: :processing, at: minutes_ago(11)})

      sweep()

      # Released: left `:processing` with a fresh `updated_at`, the new job's
      # claim would miss until the takeover came round again.
      assert %{status: :failed} = assert_redriven(row)

      [job] = jobs_for(row)
      assert :ok = WebhookWorker.perform(job)
      assert %{status: :ignored} = reload(row)
    end

    test "whose only job is executing is re-enqueued: an orphan waits on Lifeline" do
      row = event_row(%{status: :processing, at: minutes_ago(11)})
      job_in_state(row, "executing")

      sweep()

      assert %{status: :failed, redrive_count: 1} = reload(row)
      assert Enum.map(jobs_for(row), & &1.state) == ["executing", "available"]
    end

    test "inside the takeover is left alone: a worker may still hold it" do
      row = event_row(%{status: :processing, at: minutes_ago(5)})

      sweep()

      assert_untouched(row)
    end

    test "with a queued job is left alone" do
      for state <- ~w(available scheduled retryable suspended) do
        row = event_row(%{status: :processing, at: minutes_ago(11)})
        job_in_state(row, state)

        sweep()

        assert_untouched(row, 1)
      end
    end
  end

  test "the sweeper runs on its own queue, which a previous release's node does not poll" do
    # A node of the previous release polls `:default` and has no worker module
    # for these jobs.
    for trigger <- AshOban.Info.oban_triggers(WebhookEvent) do
      assert {trigger.name, trigger.queue, trigger.scheduler_queue} ==
               {trigger.name, :billing_sweeper, :billing_sweeper}
    end

    assert Application.fetch_env!(:kiln_cms, Oban)[:queues][:billing_sweeper] == 1
  end

  test "settled rows are never touched" do
    for status <- [:processed, :ignored] do
      row = event_row(%{status: status, at: minutes_ago(60 * 24 * 5)})

      sweep()

      assert_untouched(row)
    end
  end

  describe "giving up" do
    test "after three redrives the event is stamped, logged and reported, once" do
      attach_gave_up()
      row = event_row(%{status: :failed})

      for count <- 1..WebhookEvent.max_redrives() do
        sweep()
        assert_redriven(row, count)
        exhaust_jobs(row)
      end

      log = capture_log(fn -> sweep() end)

      given_up = reload(row)
      assert %DateTime{} = given_up.gave_up_at
      assert given_up.status == :failed
      assert given_up.redrive_count == WebhookEvent.max_redrives()
      refute Enum.any?(jobs_for(row), &(&1.state == "available"))

      assert log =~ "billing webhook #{row.provider_event_id} (ping) was never processed"
      assert log =~ "resend the event from the provider's dashboard"

      event_id = row.provider_event_id
      row_id = row.id

      assert_received {:gave_up, %{count: 1},
                       %{
                         webhook_event_id: ^row_id,
                         event_id: ^event_id,
                         type: "ping",
                         redrive_count: 3
                       }}

      # Stamped: the next sweep leaves it alone.
      sweep()
      assert reload(row).gave_up_at == given_up.gave_up_at
      refute_received {:gave_up, _, %{webhook_event_id: ^row_id}}
    end

    test "a stale :processing row given up on is released to :failed" do
      row =
        event_row(%{
          status: :processing,
          at: minutes_ago(11),
          redrive_count: WebhookEvent.max_redrives()
        })

      sweep()

      assert %{status: :failed, gave_up_at: %DateTime{}} = reload(row)
      assert jobs_for(row) == []
    end

    test "a provider resend re-arms the event, but its redrive count stands" do
      row = event_row(%{status: :failed, redrive_count: WebhookEvent.max_redrives()})
      sweep()
      assert %{gave_up_at: %DateTime{}} = given_up = reload(row)

      # The resend's job claims it: the give-up is cleared.
      claimed = Billing.claim_webhook_event!(given_up, actor: Billing.system())
      assert is_nil(claimed.gave_up_at)
      assert claimed.redrive_count == WebhookEvent.max_redrives()

      # It fails again and its job runs out: straight back to give-up, no
      # fourth redrive.
      Billing.mark_webhook_event_failed!(claimed, %{error: "boom"}, actor: Billing.system())
      sweep()

      assert %{gave_up_at: %DateTime{}, redrive_count: 3} = reload(row)
      assert jobs_for(row) == []
    end
  end

  describe "the age bound" do
    test "an unfinished event older than the redrive window is given up on, never replayed" do
      days = WebhookEvent.redrive_window_days()

      for status <- [:received, :failed] do
        row = event_row(%{status: status, at: minutes_ago(60 * 24 * (days + 1))})

        sweep()

        assert %{gave_up_at: %DateTime{}, redrive_count: 0} = reload(row)
        assert jobs_for(row) == []
      end
    end

    test "an event inside the window is replayed" do
      row = event_row(%{status: :failed, at: minutes_ago(60 * 24 * 2)})

      sweep()

      assert_redriven(row)
    end

    test "an old `active` event does not re-grant a canceled member with no event stamp" do
      # A row last written before 1.12, so it has no `last_provider_event_at`
      # for `EventGuard` to order a replay against: an old event would apply.
      m = membership(%{status: :canceled})
      assert is_nil(m.last_provider_event_at)

      four_days_ago = minutes_ago(60 * 24 * 4)

      payload =
        subscription_updated(m, "active")
        |> Map.put("created", DateTime.to_unix(four_days_ago))

      row =
        event_row(%{
          provider_event_id: payload["id"],
          type: payload["type"],
          payload: payload,
          at: four_days_ago
        })

      sweep()
      drain_oban()

      assert reload_membership(m).status == :canceled
      assert audiences_of(m.user_id) == []
      assert %{gave_up_at: %DateTime{}, status: :received} = reload(row)
    end
  end

  describe "rows recorded before the sweeper" do
    test "`:receive` counts from 0, so a row it records can be redriven" do
      # authorize?: false, as the receiver records: a webhook has no actor and
      # the provider's signature is the grant.
      row =
        Billing.receive_webhook_event!(
          %{provider: :stripe, provider_event_id: "evt_#{uniq()}", type: "ping", payload: %{}},
          authorize?: false
        )

      assert reload(row).redrive_count == 0
    end

    test "an unsettled one with no count is given up on, however young, never replayed" do
      # A null count: recorded by an earlier release, or by a node still on
      # the previous release during a rolling deploy. Inside the redrive
      # window and past every grace period, so only the null keeps it from
      # being replayed.
      attach_gave_up()

      for {status, at} <- [received: 60, failed: 60, processing: 11] do
        row = event_row(%{status: status, redrive_count: nil, at: minutes_ago(at)})

        log = capture_log(fn -> sweep() end)

        assert %{gave_up_at: %DateTime{}, redrive_count: nil} = reload(row)
        assert jobs_for(row) == []
        assert log =~ "recorded before the sweeper, so not replayed"

        row_id = row.id
        assert_received {:gave_up, _, %{webhook_event_id: ^row_id, redrive_count: nil}}
      end
    end

    test "a settled one with no count is never touched" do
      row = event_row(%{status: :processed, redrive_count: nil})

      sweep()

      assert_untouched(row)
    end
  end

  test "a same-event replay after a lost settle stamp applies again and changes nothing" do
    m = membership(%{status: :incomplete})
    payload = subscription_updated(m, "active")

    row =
      event_row(%{
        provider_event_id: payload["id"],
        type: payload["type"],
        payload: payload,
        at: minutes_ago(30)
      })

    assert :ok = WebhookWorker.perform(%Oban.Job{args: %{"webhook_event_id" => row.id}})
    assert reload_membership(m).status == :active
    trail = membership_events(m)
    webhooks = membership_webhook_jobs()

    # The `:mark_processed` stamp did not save: `:processing`, past the takeover.
    {1, _} =
      Repo.update_all(from(e in WebhookEvent, where: e.id == ^row.id),
        set: [status: :processing, processed_at: nil, updated_at: minutes_ago(11)]
      )

    sweep()
    assert %{status: :failed, redrive_count: 1} = reload(row)
    drain_oban()

    # Applied a second time, as a same-`created` event passes `EventGuard`:
    # settled `:processed`, not `out_of_order`, and nothing about the member moved.
    assert %{status: :processed, error: nil} = reload(row)
    assert reload_membership(m).status == :active
    assert audiences_of(m.user_id) == [@gated]
    assert [%{to_status: :active, from_status: :active} | _] = membership_events(m) -- trail
    assert membership_webhook_jobs() == webhooks
  end

  describe "a replayed checkout" do
    # `checkout.session.completed` retrieves the subscription from the
    # provider, so the double is selected through app env (see
    # `KilnCMS.StubBillingProvider`) and billing is configured.
    setup do
      previous = Application.get_env(:kiln_cms, KilnCMS.Billing, [])

      Application.put_env(
        :kiln_cms,
        KilnCMS.Billing,
        Keyword.put(previous, :provider, KilnCMS.StubBillingProvider)
      )

      on_exit(fn ->
        Application.put_env(:kiln_cms, KilnCMS.Billing, previous)
        Application.delete_env(:kiln_cms, :stub_billing_provider)
      end)

      settings = Billing.ensure_settings!()

      {:ok, settings} =
        Billing.store_billing_secret(settings, :secret_key, "sk_test_abc", authorize?: false)

      {:ok, _settings} =
        Billing.store_billing_secret(settings, :webhook_secret, "whsec_test", authorize?: false)

      :ok
    end

    test "does not move the ordering stamp back, so an older `active` cannot re-grant" do
      # T0 < T1 < T2: the checkout, an `active` the provider is still retrying,
      # and the cancel that was applied.
      t0 = DateTime.truncate(minutes_ago(120), :second)
      t1 = DateTime.truncate(minutes_ago(90), :second)
      t2 = DateTime.truncate(minutes_ago(60), :second)

      m = membership(%{status: :canceled, last_provider_event_at: t2})

      KilnCMS.StubBillingProvider.put(
        :subscription,
        KilnCMS.StubBillingProvider.subscription(m.provider_subscription_id, "canceled")
      )

      checkout = checkout_completed(m, t0)

      row =
        event_row(%{
          provider_event_id: checkout["id"],
          type: checkout["type"],
          payload: checkout,
          status: :failed,
          at: t0
        })

      sweep()
      drain_oban()

      assert %{status: :processed} = reload(row)
      assert %{status: :canceled} = reloaded = reload_membership(m)
      assert DateTime.compare(reloaded.last_provider_event_at, t2) == :eq

      active =
        subscription_updated(m, "active")
        |> Map.put("created", DateTime.to_unix(t1))

      late =
        event_row(%{
          provider_event_id: active["id"],
          type: active["type"],
          payload: active,
          at: minutes_ago(30)
        })

      assert :ok = WebhookWorker.perform(%Oban.Job{args: %{"webhook_event_id" => late.id}})

      assert %{status: :ignored} = reload(late)
      assert %{status: :canceled} = reloaded = reload_membership(m)
      assert DateTime.compare(reloaded.last_provider_event_at, t2) == :eq
      assert audiences_of(m.user_id) == []
    end
  end

  describe "the triggers and their actions agree (ADR 0074)" do
    test "an action run on a row its trigger would not pick fails with a single StaleRecord" do
      settled = event_row(%{status: :processed})
      due = event_row(%{status: :failed})
      spent = event_row(%{status: :failed, redrive_count: WebhookEvent.max_redrives()})

      for {action, row} <- [
            {&Billing.redrive_webhook_event/2, settled},
            {&Billing.redrive_webhook_event/2, spent},
            {&Billing.give_up_webhook_event/2, settled},
            {&Billing.give_up_webhook_event/2, due}
          ] do
        assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
                 action.(row, context: @oban_context)
      end

      assert %{redrive_count: 0, gave_up_at: nil} = reload(due)
      assert %{redrive_count: 3, gave_up_at: nil} = reload(spent)
    end

    # The actions are atomic, so AshOban's worker runs them as a bulk update
    # over the trigger's `where`: a row that stopped matching is a zero-row
    # `UPDATE`, and the job completes having written nothing.
    test "a row that got a job after the scan is not redriven" do
      row = event_row(%{status: :failed})
      AshOban.run_trigger(row, :redrive)

      # The provider resent it in between.
      {:ok, _job} = WebhookWorker.enqueue(row)

      assert %{success: 1} = Oban.drain_queue(queue: :billing_sweeper)
      assert %{redrive_count: 0} = reload(row)
      assert length(jobs_for(row)) == 1
    end
  end

  describe "a failed enqueue" do
    setup do
      on_exit(fn -> Application.delete_env(:kiln_cms, :billing_webhook_insert) end)
    end

    test "rolls the redrive back, so the next sweep tries again" do
      row = event_row(%{status: :failed})

      Application.put_env(:kiln_cms, :billing_webhook_insert, fn _changeset ->
        {:error, :pool_timeout}
      end)

      sweep()
      assert_untouched(row)

      Application.delete_env(:kiln_cms, :billing_webhook_insert)
      sweep()
      assert_redriven(row)
    end
  end

  describe "who may run the sweeper's actions" do
    test "nobody but its triggers: not a platform admin, not the billing system actor, not a member" do
      row = event_row(%{status: :failed})

      for actor <- [user(:admin), Billing.system(), user(:viewer), nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Billing.redrive_webhook_event(row, actor: actor)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Billing.give_up_webhook_event(row, actor: actor)
      end

      assert_untouched(row)

      # The trigger's path is the bypass.
      assert {:ok, %{redrive_count: 1}} =
               Billing.redrive_webhook_event(row, context: @oban_context)
    end
  end

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "sweep-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp membership(attrs) do
    tier =
      Ash.Seed.seed!(Billing.MembershipTier, %{
        org_id: org_id(),
        name: "Tier #{uniq()}",
        slug: "sweep-tier-#{uniq()}",
        audience: @gated,
        provider_price_id: "price_#{uniq()}"
      })

    Ash.Seed.seed!(
      Billing.Membership,
      Map.merge(
        %{
          org_id: org_id(),
          user_id: user(:viewer).id,
          tier_id: tier.id,
          provider_subscription_id: "sub_#{uniq()}",
          provider_customer_id: "cus_#{uniq()}"
        },
        attrs
      )
    )
  end

  defp subscription_updated(m, status) do
    %{
      "id" => "evt_#{uniq()}",
      "type" => "customer.subscription.updated",
      "created" => System.os_time(:second),
      "data" => %{
        "object" => %{
          "object" => "subscription",
          "id" => m.provider_subscription_id,
          "status" => status,
          "customer" => m.provider_customer_id
        }
      }
    }
  end

  defp checkout_completed(m, created) do
    %{
      "id" => "evt_#{uniq()}",
      "type" => "checkout.session.completed",
      "created" => DateTime.to_unix(created),
      "data" => %{
        "object" => %{
          "object" => "checkout.session",
          "id" => "cs_#{uniq()}",
          "mode" => "subscription",
          "customer" => m.provider_customer_id,
          "subscription" => m.provider_subscription_id,
          "metadata" => %{
            "membership_id" => m.id,
            "org_id" => m.org_id,
            "user_id" => m.user_id
          }
        }
      }
    }
  end

  defp reload_membership(m),
    do: Billing.get_membership!(m.id, actor: Billing.system(), tenant: m.org_id)

  defp membership_events(m),
    do: Billing.membership_events!(m.id, authorize?: false, tenant: m.org_id)

  defp membership_webhook_jobs do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == "KilnCMS.Billing.MembershipWebhookWorker",
        select: j.id
      )
    )
  end

  defp audiences_of(user_id) do
    {:ok, user} = Accounts.get_user(user_id, authorize?: false)
    user.audiences
  end
end
