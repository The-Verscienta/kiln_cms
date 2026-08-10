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

  # #753 moved the worker onto `KilnCMS.SafeFetch`, deleting its own copy of the
  # address pinning and TLS options. These two pin the seam: the request the
  # receiver sees still carries what the worker is responsible for, and a URL
  # the address check refuses still lands on the ledger in the vocabulary
  # `KilnCMS.CMS.WebhookDelivery` documents.
  test "the signed request still reaches the receiver intact" do
    test_pid = self()

    Req.Test.stub(KilnCMS.Webhooks, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:received, conn.method, body,
         %{
           signature: Plug.Conn.get_req_header(conn, Webhooks.signature_header()),
           event: Plug.Conn.get_req_header(conn, Webhooks.event_header()),
           content_type: Plug.Conn.get_req_header(conn, "content-type")
         }}
      )

      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    endpoint = endpoint!()

    Webhooks.dispatch("page.published", %{"title" => "Hello"})
    drain_with_retries()

    assert_received {:received, "POST", body, headers}

    assert Jason.decode!(body) == %{"event" => "page.published", "data" => %{"title" => "Hello"}}
    assert headers.event == ["page.published"]
    assert headers.content_type == ["application/json"]
    assert headers.signature == [Webhooks.signature(endpoint.secret, body)]
  end

  test "a URL the address check refuses is recorded, not dialled" do
    # Seeded rather than created: `Validations.WebhookUrl` refuses this at the
    # write, which is the point — the worker's own check is the second line, for
    # a row that predates the validation or a name that changed answer since.
    endpoint =
      Ash.Seed.seed!(KilnCMS.CMS.WebhookEndpoint, %{
        url: "http://169.254.169.254/latest/meta-data/",
        secret: "s3cret",
        events: ["page.published"],
        active: true
      })

    # No stub installed: reaching Req at all would be the failure.
    Webhooks.dispatch("page.published", %{})
    drain_with_retries()

    assert [delivery] = deliveries()
    assert delivery.endpoint_id == endpoint.id
    assert delivery.status == :failed
    # The ledger's documented wording, kept verbatim across the move to
    # SafeFetch. Compared whole: a `=~ "blocked webhook URL:"` passed on
    # "blocked webhook blocked URL: …", which is what the first attempt at the
    # prefix rewrite actually produced.
    assert delivery.last_error ==
             "blocked webhook URL: must not target private or link-local addresses"

    assert delivery.last_status == nil
  end

  # `truncate_body: true` is the one line of the #753 move that can change a
  # delivery outcome, and deleting it left the whole suite green. `SafeFetch`
  # imposes a 256KB cap the worker never had; without truncation an over-cap
  # response becomes `{:error, "response exceeded 262144 bytes"}` — a receiver
  # that answered 200 recorded as a permanent failure, counting toward
  # auto-disable. Only the status decides the ledger, so the body is irrelevant.
  test "a receiver that answers 200 with a huge body is still a delivered 200" do
    Req.Test.stub(KilnCMS.Webhooks, fn conn ->
      Plug.Conn.send_resp(conn, 200, String.duplicate("x", 300 * 1024))
    end)

    endpoint!()
    Webhooks.dispatch("page.published", %{})
    drain_with_retries()

    assert [delivery] = deliveries()
    assert delivery.status == :succeeded
    assert delivery.last_status == 200
    assert delivery.attempts == 1
  end

  # `SafeFetch` prefixes its own transport failures with "request failed: ", so
  # wrapping them produced "delivery failed: request failed: %Mint.…{}" — the
  # ledger's documented vocabulary with somebody else's inside it. Each shape is
  # translated, and this pins the translation so a reworded SafeFetch goes red.
  test "a transport failure reads the way the ledger documents it" do
    Req.Test.stub(KilnCMS.Webhooks, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    endpoint!()
    Webhooks.dispatch("page.published", %{})
    drain_with_retries()

    assert [delivery] = deliveries()
    assert delivery.status == :failed
    assert delivery.last_error == "delivery failed: %Req.TransportError{reason: :timeout}"
    refute delivery.last_error =~ "request failed:"
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
