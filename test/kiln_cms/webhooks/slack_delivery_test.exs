defmodule KilnCMS.Webhooks.SlackDeliveryTest do
  @moduledoc """
  Delivering to a Slack-format endpoint (#2245), and what a delivery keeps of
  an endpoint's URL: the Slack body is what is signed and sent, a ping to
  Slack carries no URL while a Kiln ping is unchanged, the ledger keeps the
  real URL, content never goes to a Slack endpoint, and Slack's refusals fail
  a delivery like any other.

  `async: false`: the auto-disable threshold is an `Application.put_env`.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.WebhookEndpoint
  alias KilnCMS.Test.SecurityAlerts
  alias KilnCMS.Webhooks

  @moduletag :capture_log

  @slack_url "https://hooks.slack.test/services/T0001/B0002/s3cr3tT0kenZq9x"
  @kiln_url "https://receiver.test/hooks/kiln/T0SECRET-kiln-Kn01"

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
      email: "whs-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp slack!(attrs \\ %{}),
    do:
      CMS.create_webhook_endpoint!(Map.merge(%{url: @slack_url, format: :slack}, attrs),
        actor: admin()
      )

  defp kiln!(attrs),
    do: CMS.create_webhook_endpoint!(Map.merge(%{url: @kiln_url}, attrs), actor: admin())

  # A receiver that answers `status` with `body` and reports what it was sent.
  defp stub(status \\ 200, response \\ "ok") do
    test_pid = self()

    Req.Test.stub(KilnCMS.Webhooks, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:posted, conn.host, conn.request_path, Map.new(conn.req_headers), body})
      Plug.Conn.send_resp(conn, status, response)
    end)
  end

  defp drain, do: Oban.drain_queue(queue: :webhooks, with_scheduled: true, with_recursion: true)

  defp deliveries, do: CMS.recent_webhook_deliveries!(authorize?: false)

  # What `KilnCMS.Security.Changes.DeliverAlert` hands the ledger.
  defp alert_data do
    %{
      phase: "alert",
      channel: "site",
      site_id: org_id(),
      site_name: "Example",
      console_url: "https://console.test/editor/security-log",
      kind: "lockout",
      occurred_at: "2026-11-10T14:03:27Z",
      window: %{started_at: "2026-11-10T14:00:00Z", ends_at: "2026-11-10T14:15:00Z"},
      count: 1,
      event: %{id: Ecto.UUID.generate(), type: "lockout", ip: "203.0.113.0/24", metadata: %{}}
    }
  end

  test "a Slack endpoint is sent the Slack body, signed over exactly that body" do
    stub()
    endpoint = slack!()

    delivery = Webhooks.enqueue_security!(endpoint, "security.lockout", alert_data(), org_id())
    drain()

    assert_received {:posted, "hooks.slack.test", "/services/T0001/B0002/s3cr3tT0kenZq9x",
                     headers, body}

    assert %{"text" => text, "blocks" => [_ | _], "unfurl_links" => false} = Jason.decode!(body)
    assert text =~ "Security alert on `Example`: An account was locked out"
    refute body =~ delivery.id

    assert headers["x-kilncms-event"] == "security.lockout"
    assert headers["x-kilncms-delivery-id"] == delivery.id

    secret = WebhookEndpoint.secret(endpoint)
    assert Webhooks.verify(secret, body, headers["x-kilncms-webhook-signature"]) == :ok

    assert [%{status: :succeeded}] = deliveries()
  end

  describe "a ping" do
    test "to a Slack endpoint names the site and carries no URL" do
      stub()
      endpoint = slack!()

      delivery = Webhooks.ping(endpoint)
      refute Map.has_key?(delivery.payload, :endpoint_url)

      drain()

      assert_received {:posted, _host, _path, _headers, body}
      site = KilnCMS.Branding.for_org(org_id()).site_name
      assert Jason.decode!(body)["text"] == "KilnCMS webhook test for `#{site}`"
      refute body =~ "s3cr3tT0ken"
      refute body =~ "hooks.slack.test"
    end

    # The ping payload is a 1.x webhook contract: unchanged for Kiln receivers.
    test "to a Kiln endpoint is unchanged, the full URL included" do
      stub()
      endpoint = kiln!(%{})

      Webhooks.ping(endpoint)
      drain()

      assert_received {:posted, _host, _path, _headers, body}

      assert %{
               "event" => "ping",
               "data" => %{"message" => "KilnCMS webhook test", "endpoint_url" => @kiln_url},
               "delivery_id" => _
             } = Jason.decode!(body)
    end
  end

  test "the ledger keeps the real URL, and a redelivery posts to it" do
    stub(500)
    endpoint = kiln!(%{events: ["page.published"]})

    Webhooks.dispatch("page.published", %{"title" => "Hello"}, org_id(), announce: :delivery)
    drain()

    assert [failed] = deliveries()
    assert failed.endpoint_url == endpoint.url

    stub(200)
    Webhooks.redeliver(failed)
    drain()

    assert_received {:posted, "receiver.test", "/hooks/kiln/T0SECRET-kiln-Kn01", _headers, _body}
  end

  # Security events are never dispatched this way; if one were, only Kiln
  # endpoints would get it.
  test "dispatch never enqueues to a Slack endpoint" do
    stub()
    kiln = kiln!(%{events: ["security.lockout"]})
    slack = slack!(%{events: ["security.lockout"]})

    Webhooks.dispatch("security.lockout", %{}, org_id(), announce: :delivery)

    endpoint_ids = Enum.map(deliveries(), & &1.endpoint_id)
    assert kiln.id in endpoint_ids
    refute slack.id in endpoint_ids
  end

  test "an endpoint of a format this release does not know is refused, not sent" do
    stub()
    endpoint = kiln!(%{})

    KilnCMS.Repo.query!(
      "UPDATE webhook_endpoints SET format = 'teams' WHERE id = $1::text::uuid",
      [endpoint.id]
    )

    endpoint = CMS.get_webhook_endpoint!(endpoint.id, authorize?: false)
    Webhooks.ping(endpoint)
    drain()

    refute_received {:posted, _host, _path, _headers, _body}

    assert [%{status: :failed, last_error: "delivery failed: endpoint format not supported" <> _}] =
             deliveries()
  end

  test "Slack's 400 invalid_payload fails the delivery, and exhaustion auto-disables with a notice" do
    put_webhook_env(auto_disable_after: 1)
    stub(400, "invalid_payload")
    endpoint = slack!()

    Webhooks.enqueue_security!(endpoint, "security.lockout", alert_data(), org_id())
    drain()

    assert [%{status: :failed, last_status: 400}] = deliveries()

    reloaded = CMS.get_webhook_endpoint!(endpoint.id, authorize?: false)
    refute reloaded.active
    assert reloaded.auto_disabled_at

    assert [%{"change" => "webhook_auto_disabled", "endpoint_id" => id}] =
             Enum.map(SecurityAlerts.dispatches(), & &1["notice"])

    assert id == endpoint.id
  end
end
