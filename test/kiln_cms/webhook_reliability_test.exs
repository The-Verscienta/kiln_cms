defmodule KilnCMS.WebhookReliabilityTest do
  @moduledoc """
  The webhook reliability layer: every delivery is recorded on the
  `WebhookDelivery` ledger (per-attempt status/error), exhausted deliveries
  count against the endpoint until it auto-disables, successes reset the
  count, failed deliveries can be replayed, admins can ping a receiver, and
  old ledger rows are pruned.
  """
  # async: false — tweaks the global auto-disable threshold via app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Webhooks

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Webhooks, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Webhooks, original) end)
    :ok
  end

  defp put_webhook_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Webhooks, [])
    Application.put_env(:kiln_cms, KilnCMS.Webhooks, Keyword.merge(base, overrides))
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "whr-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp endpoint!(attrs \\ %{}) do
    CMS.create_webhook_endpoint!(
      Map.merge(%{url: "https://example.test/hook"}, attrs),
      actor: admin()
    )
  end

  defp stub_status(status) do
    Req.Test.stub(KilnCMS.Webhooks, fn conn ->
      Plug.Conn.send_resp(conn, status, "{}")
    end)
  end

  # Drain the webhooks queue *including scheduled retries*, so a failing job
  # burns through all its attempts inline.
  defp drain_with_retries do
    Oban.drain_queue(queue: :webhooks, with_scheduled: true, with_recursion: true)
  end

  defp deliveries do
    CMS.recent_webhook_deliveries!(authorize?: false)
  end

  test "a successful delivery is recorded on the ledger" do
    stub_status(200)
    endpoint = endpoint!()

    Webhooks.dispatch("page.published", %{"title" => "Hello"})
    drain_with_retries()

    assert [delivery] = deliveries()
    assert delivery.endpoint_id == endpoint.id
    assert delivery.status == :succeeded
    assert delivery.attempts == 1
    assert delivery.last_status == 200
    assert delivery.delivered_at
    assert delivery.event == "page.published"
  end

  test "a failing delivery retries, exhausts onto the ledger, and counts against the endpoint" do
    stub_status(503)
    endpoint = endpoint!()

    Webhooks.dispatch("page.published", %{})
    drain_with_retries()

    assert [delivery] = deliveries()
    assert delivery.status == :failed
    assert delivery.attempts == 5
    assert delivery.last_status == 503
    assert delivery.last_error =~ "HTTP 503"

    reloaded = CMS.get_webhook_endpoint!(endpoint.id, authorize?: false)
    assert reloaded.consecutive_failures == 1
    assert reloaded.active
  end

  test "enough exhausted deliveries in a row auto-disable the endpoint" do
    stub_status(500)
    put_webhook_env(auto_disable_after: 2)
    endpoint = endpoint!()

    Webhooks.dispatch("page.published", %{})
    drain_with_retries()
    Webhooks.dispatch("page.published", %{})
    drain_with_retries()

    reloaded = CMS.get_webhook_endpoint!(endpoint.id, authorize?: false)
    assert reloaded.consecutive_failures == 2
    refute reloaded.active
    assert reloaded.auto_disabled_at
  end

  test "a success resets the failure count" do
    endpoint = endpoint!()
    CMS.record_webhook_failure!(endpoint, %{}, authorize?: false)

    stub_status(200)
    Webhooks.dispatch("page.published", %{})
    drain_with_retries()

    reloaded = CMS.get_webhook_endpoint!(endpoint.id, authorize?: false)
    assert reloaded.consecutive_failures == 0
    assert is_nil(reloaded.auto_disabled_at)
  end

  test "redeliver replays a failed delivery as a fresh ledger row" do
    stub_status(500)
    endpoint!()

    Webhooks.dispatch("page.published", %{"title" => "Retry me"})
    drain_with_retries()
    assert [failed] = deliveries()
    assert failed.status == :failed

    # The receiver comes back to life; the replay succeeds.
    stub_status(200)
    Webhooks.redeliver(failed)
    drain_with_retries()

    rows = deliveries()
    assert length(rows) == 2
    replay = Enum.find(rows, &(&1.id != failed.id))
    assert replay.status == :succeeded
    assert replay.event == failed.event
    assert replay.payload == failed.payload
    # History stays immutable.
    assert CMS.get_webhook_delivery!(failed.id, authorize?: false).status == :failed
  end

  test "ping delivers a test event — even to an inactive endpoint" do
    test_pid = self()

    Req.Test.stub(KilnCMS.Webhooks, fn conn ->
      send(test_pid, {:event, Plug.Conn.get_req_header(conn, "x-kilncms-event")})
      Req.Test.json(conn, %{ok: true})
    end)

    endpoint = endpoint!(%{active: false})

    Webhooks.ping(endpoint)
    drain_with_retries()

    assert_received {:event, ["ping"]}
    assert [%{event: "ping", status: :succeeded}] = deliveries()
  end

  test "a regular delivery to an endpoint disabled mid-flight settles as failed" do
    stub_status(200)
    endpoint = endpoint!()

    # Enqueue, then disable before the worker runs.
    delivery =
      CMS.create_webhook_delivery!(
        %{endpoint_id: endpoint.id, event: "page.published", payload: %{}},
        authorize?: false
      )

    CMS.update_webhook_endpoint!(endpoint, %{active: false}, actor: admin())

    %{delivery_id: delivery.id} |> KilnCMS.Webhooks.DeliveryWorker.new() |> Oban.insert!()
    drain_with_retries()

    assert CMS.get_webhook_delivery!(delivery.id, authorize?: false).status == :failed
    assert CMS.get_webhook_delivery!(delivery.id, authorize?: false).last_error =~ "inactive"
  end

  test "old ledger rows are pruned by the retention trigger" do
    endpoint = endpoint!()
    retention = KilnCMS.CMS.WebhookDelivery.retention_days()

    old =
      Ash.Seed.seed!(KilnCMS.CMS.WebhookDelivery, %{
        endpoint_id: endpoint.id,
        event: "page.published",
        payload: %{},
        status: :succeeded,
        inserted_at: DateTime.add(DateTime.utc_now(), -(retention + 1), :day)
      })

    fresh =
      Ash.Seed.seed!(KilnCMS.CMS.WebhookDelivery, %{
        endpoint_id: endpoint.id,
        event: "page.published",
        payload: %{},
        status: :succeeded
      })

    AshOban.schedule_and_run_triggers(KilnCMS.CMS.WebhookDelivery,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )

    ids = deliveries() |> Enum.map(& &1.id)
    refute old.id in ids
    assert fresh.id in ids
  end
end
