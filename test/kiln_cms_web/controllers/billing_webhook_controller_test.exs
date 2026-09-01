defmodule KilnCMSWeb.BillingWebhookControllerTest do
  @moduledoc """
  The inbound webhook receiver, end to end.

  `async: false`: these tests configure billing credentials on the instance-wide
  settings singleton and drive `Req.Test` stubs, neither of which is per-test
  isolated.

  The replay tests are the ones that matter — they are the acceptance criterion
  "webhook replay / duplicate delivery cannot double-grant, double-revoke, or
  corrupt membership state" expressed executably, and they exercise all three
  idempotency layers independently.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.Providers.Stripe.Signature
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())
  @secret "whsec_test_secret"
  @path "/billing/webhooks/stripe"

  setup do
    # The provider double is selected through APP ENV, not `Req.Test`. A
    # `Req.Test` stub is process-scoped and the Oban worker runs in a different
    # process, so it falls through to the real network — which made an earlier
    # version of this file issue a live request to the payment provider.
    Application.put_env(:kiln_cms, KilnCMS.Billing, provider: KilnCMS.StubBillingProvider)

    on_exit(fn ->
      Application.delete_env(:kiln_cms, KilnCMS.Billing)
      Application.delete_env(:kiln_cms, :stub_billing_provider)
    end)

    settings = Billing.ensure_settings!()

    {:ok, settings} =
      Billing.store_billing_secret(settings, :secret_key, "sk_test_abc", authorize?: false)

    {:ok, _settings} =
      Billing.store_billing_secret(settings, :webhook_secret, @secret, authorize?: false)

    :ok
  end

  defp default_org_id, do: Accounts.default_org_id()

  defp member do
    Ash.Seed.seed!(User, %{
      email: "member-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :viewer
    })
  end

  defp tier(org_id \\ nil) do
    Billing.create_tier!(
      %{
        name: "Supporter",
        slug: "supporter-#{System.unique_integer([:positive])}",
        audience: @gated,
        provider_price_id: "price_#{System.unique_integer([:positive])}"
      },
      authorize?: false,
      tenant: org_id || default_org_id()
    )
  end

  defp membership(user, tier, status \\ :incomplete, org_id \\ nil) do
    Ash.Seed.seed!(Billing.Membership, %{
      org_id: org_id || default_org_id(),
      user_id: user.id,
      tier_id: tier.id,
      status: status
    })
  end

  defp audiences_of(user_id) do
    {:ok, user} = Accounts.get_user(user_id, authorize?: false)
    user.audiences
  end

  # A `checkout.session.completed` whose metadata makes it self-describing.
  defp checkout_event(membership, opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, "evt_#{System.unique_integer([:positive])}"),
      "type" => "checkout.session.completed",
      "data" => %{
        "object" => %{
          "object" => "checkout.session",
          "id" => "cs_#{System.unique_integer([:positive])}",
          "mode" => "subscription",
          "customer" => "cus_123",
          "subscription" => "sub_#{System.unique_integer([:positive])}",
          "metadata" => %{
            "membership_id" => membership.id,
            "org_id" => membership.org_id,
            "user_id" => membership.user_id
          }
        }
      }
    }
  end

  defp subscription_event(type, membership, attrs) do
    %{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => type,
      "data" => %{
        "object" =>
          Map.merge(
            %{
              "object" => "subscription",
              "id" => "sub_#{System.unique_integer([:positive])}",
              "customer" => "cus_123",
              "metadata" => %{
                "membership_id" => membership.id,
                "org_id" => membership.org_id,
                "user_id" => membership.user_id
              }
            },
            attrs
          )
      }
    }
  end

  # `checkout.session.completed` retrieves the subscription so the happy path
  # activates on one event; point the double at the status this test wants.
  defp stub_subscription(status \\ "active") do
    KilnCMS.StubBillingProvider.put(
      :subscription,
      KilnCMS.StubBillingProvider.subscription("sub_stub", status)
    )
  end

  defp post_event(conn, event, opts \\ []) do
    body = Jason.encode!(event)
    timestamp = Keyword.get(opts, :timestamp, System.system_time(:second))
    signature = Keyword.get(opts, :signature, Signature.sign(timestamp, body, @secret))

    conn = if host = opts[:host], do: %{conn | host: host}, else: conn

    conn
    |> put_req_header("content-type", "application/json")
    |> then(fn c ->
      case Keyword.get(opts, :header, :sign) do
        :sign -> put_req_header(c, "stripe-signature", "t=#{timestamp},v1=#{signature}")
        :none -> c
        raw -> put_req_header(c, "stripe-signature", raw)
      end
    end)
    |> post(@path, body)
  end

  defp event_rows do
    Billing.WebhookEvent
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.read!()
  end

  defp membership_events(membership_id) do
    Billing.membership_events!(membership_id, authorize?: false, tenant: default_org_id())
  end

  describe "replay and duplicate delivery" do
    test "the identical event twice grants exactly once", %{conn: conn} do
      # The acceptance criterion, layer by layer.
      stub_subscription()
      u = member()
      m = membership(u, tier())
      event = checkout_event(m)

      assert post_event(conn, event).status == 200
      KilnCMS.DataCase.drain_oban()

      assert audiences_of(u.id) == [@gated]
      assert length(membership_events(m.id)) == 1
      assert length(event_rows()) == 1

      # Layer 1: the unique identity on the dedupe insert.
      assert post_event(build_conn(), event).status == 200
      KilnCMS.DataCase.drain_oban()

      assert audiences_of(u.id) == [@gated]
      assert length(membership_events(m.id)) == 1, "a replay must not append a second audit row"
      assert length(event_rows()) == 1, "a replay must not insert a second event row"
    end

    test "re-running the worker on the same event row is cancelled", %{conn: conn} do
      # Layer 2: the atomic claim. Oban can execute a job more than once.
      stub_subscription()
      u = member()
      m = membership(u, tier())

      assert post_event(conn, checkout_event(m)).status == 200
      KilnCMS.DataCase.drain_oban()

      [row] = event_rows()

      assert {:cancel, :already_claimed} =
               KilnCMS.Billing.WebhookWorker.perform(%Oban.Job{
                 args: %{"webhook_event_id" => row.id}
               })

      assert length(membership_events(m.id)) == 1
      assert audiences_of(u.id) == [@gated]
    end

    test "two concurrent deliveries of one event insert a single row", %{conn: conn} do
      stub_subscription()
      u = member()
      m = membership(u, tier())
      event = checkout_event(m)

      # Both are acked; only one row exists.
      assert post_event(conn, event).status == 200
      assert post_event(build_conn(), event).status == 200

      assert length(event_rows()) == 1

      KilnCMS.DataCase.drain_oban()
      assert audiences_of(u.id) == [@gated]
      assert length(membership_events(m.id)) == 1
    end
  end

  describe "signature verification" do
    test "a body mutated after signing is rejected", %{conn: conn} do
      # The raw-body assertion at the HTTP boundary.
      u = member()
      m = membership(u, tier())
      event = checkout_event(m)

      body = Jason.encode!(event)
      timestamp = System.system_time(:second)
      signature = Signature.sign(timestamp, body, @secret)
      tampered = String.replace(body, "subscription", "subscriptio_")

      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=#{timestamp},v1=#{signature}")
        |> post(@path, tampered)

      assert resp.status == 400
      assert event_rows() == []
      assert audiences_of(u.id) == []
    end

    test "a missing signature header is rejected", %{conn: conn} do
      m = membership(member(), tier())

      assert post_event(conn, checkout_event(m), header: :none).status == 400
      assert event_rows() == []
    end

    test "a stale timestamp is rejected", %{conn: conn} do
      m = membership(member(), tier())
      stale = System.system_time(:second) - 4000

      assert post_event(conn, checkout_event(m), timestamp: stale).status == 400
      assert event_rows() == []
    end

    test "a garbage signature header is rejected, not a crash", %{conn: conn} do
      m = membership(member(), tier())

      assert post_event(conn, checkout_event(m), header: "nonsense").status == 400
      assert event_rows() == []
    end

    test "an empty body is rejected before verification, not treated as signed" do
      # The signature is over the raw bytes, so an empty body can be signed
      # perfectly well — `raw_body/1` is what refuses it. 400 rather than 500:
      # a 5xx here makes the provider retry for days and then disable the
      # endpoint, and there is nothing to retry.
      timestamp = System.system_time(:second)

      conn =
        KilnCMS.RateLimitHelpers.client_conn(Phoenix.ConnTest.build_conn())
        |> elem(0)
        |> put_req_header("content-type", "application/json")
        |> put_req_header(
          "stripe-signature",
          "t=#{timestamp},v1=#{Signature.sign(timestamp, "", @secret)}"
        )
        |> post(@path, "")

      assert conn.status == 400
      assert event_rows() == []
    end

    test "a correctly signed body that is not an event is rejected", %{conn: conn} do
      # Verification passes — the bytes really are signed with our secret — and
      # the payload still names no event. `identify/1` is the guard, and its
      # answer has to be a 400 rather than a match error further in.
      assert post_event(conn, %{"not" => "an event"}).status == 400

      assert post_event(conn, %{"id" => 123, "type" => "checkout.session.completed"}).status ==
               400

      assert event_rows() == []
    end

    test "a body with unusual key order and non-ASCII metadata still verifies", %{conn: conn} do
      # The regression guard: this fails the moment anyone re-encodes the parsed
      # body instead of using the preserved raw bytes.
      stub_subscription()
      u = member()
      m = membership(u, tier())

      body =
        ~s({"type":"checkout.session.completed","id":"evt_unicode","data":{"object":{"note":"café — ünïcode","mode":"subscription","object":"checkout.session","subscription":"sub_x","customer":"cus_123","metadata":{"user_id":"#{m.user_id}","org_id":"#{m.org_id}","membership_id":"#{m.id}"}}}})

      timestamp = System.system_time(:second)

      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header(
          "stripe-signature",
          "t=#{timestamp},v1=#{Signature.sign(timestamp, body, @secret)}"
        )
        |> post(@path, body)

      assert resp.status == 200
      KilnCMS.DataCase.drain_oban()
      assert audiences_of(u.id) == [@gated]
    end
  end

  describe "host independence" do
    test "the event lands in the org named by its metadata, not the request host", %{conn: conn} do
      # `SetTenant` resolves from `conn.host` and falls back to the DEFAULT org for
      # an unknown host, so a receiver that trusted the ambient tenant would write
      # into the wrong site. This is that hazard as an assertion.
      stub_subscription()
      u = member()
      m = membership(u, tier())

      assert post_event(conn, checkout_event(m), host: "totally-unknown-host.invalid").status ==
               200

      KilnCMS.DataCase.drain_oban()

      {:ok, reloaded} = Billing.get_membership(m.id, authorize?: false, tenant: m.org_id)
      assert reloaded.status == :active
      assert audiences_of(u.id) == [@gated]
    end
  end

  describe "state machine" do
    test "subscription.deleted revokes", %{conn: conn} do
      u = member()
      m = membership(u, tier(), :active)

      # Grant first.
      {:ok, _delta} = KilnCMS.Billing.Entitlements.recompute(u.id)
      assert audiences_of(u.id) == [@gated]

      event = subscription_event("customer.subscription.deleted", m, %{"status" => "canceled"})
      assert post_event(conn, event).status == 200
      KilnCMS.DataCase.drain_oban()

      assert audiences_of(u.id) == []
    end

    test "invoice.payment_failed sets past_due and KEEPS the audience", %{conn: conn} do
      u = member()
      m = membership(u, tier(), :active)
      {:ok, _delta} = KilnCMS.Billing.Entitlements.recompute(u.id)

      event = %{
        "id" => "evt_failed_#{System.unique_integer([:positive])}",
        "type" => "invoice.payment_failed",
        "data" => %{
          "object" => %{
            "object" => "invoice",
            "customer" => "cus_123",
            "metadata" => %{
              "membership_id" => m.id,
              "org_id" => m.org_id,
              "user_id" => m.user_id
            }
          }
        }
      }

      assert post_event(conn, event).status == 200
      KilnCMS.DataCase.drain_oban()

      {:ok, reloaded} = Billing.get_membership(m.id, authorize?: false, tenant: m.org_id)
      assert reloaded.status == :past_due
      # Dunning is still in progress — access must survive it.
      assert audiences_of(u.id) == [@gated]
    end

    test "invoice.payment_failed on a canceled membership is ignored", %{conn: conn} do
      u = member()
      m = membership(u, tier(), :canceled)

      event = %{
        "id" => "evt_late_#{System.unique_integer([:positive])}",
        "type" => "invoice.payment_failed",
        "data" => %{
          "object" => %{
            "object" => "invoice",
            "metadata" => %{"membership_id" => m.id, "org_id" => m.org_id}
          }
        }
      }

      assert post_event(conn, event).status == 200
      KilnCMS.DataCase.drain_oban()

      {:ok, reloaded} = Billing.get_membership(m.id, authorize?: false, tenant: m.org_id)
      assert reloaded.status == :canceled

      [row] = event_rows()
      assert row.status == :ignored
    end

    test "an unpaid subscription revokes — dunning is exhausted", %{conn: conn} do
      u = member()
      m = membership(u, tier(), :active)
      {:ok, _delta} = KilnCMS.Billing.Entitlements.recompute(u.id)

      event = subscription_event("customer.subscription.updated", m, %{"status" => "unpaid"})
      assert post_event(conn, event).status == 200
      KilnCMS.DataCase.drain_oban()

      assert audiences_of(u.id) == []
    end

    test "cancel_at_period_end keeps access while the provider says active", %{conn: conn} do
      u = member()
      m = membership(u, tier(), :active)
      {:ok, _delta} = KilnCMS.Billing.Entitlements.recompute(u.id)

      event =
        subscription_event("customer.subscription.updated", m, %{
          "status" => "active",
          "cancel_at_period_end" => true,
          "current_period_end" =>
            DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.to_unix()
        })

      assert post_event(conn, event).status == 200
      KilnCMS.DataCase.drain_oban()

      {:ok, reloaded} = Billing.get_membership(m.id, authorize?: false, tenant: m.org_id)
      assert reloaded.cancel_at_period_end
      assert reloaded.current_period_end
      # No local timer: the provider is still saying active, so access remains.
      assert audiences_of(u.id) == [@gated]
    end

    test "the audit trail records the audience delta and the causing event", %{conn: conn} do
      stub_subscription()
      u = member()
      m = membership(u, tier())
      event = checkout_event(m)

      assert post_event(conn, event).status == 200
      KilnCMS.DataCase.drain_oban()

      [audit] = membership_events(m.id)
      assert audit.audiences_added == [@gated]
      assert audit.audiences_removed == []
      assert audit.to_status == :active
      assert audit.provider_event_id == event["id"]
      # Webhook-driven, so no human actor — the provenance is the event id.
      refute audit.actor_id
    end
  end

  describe "governance visibility" do
    test "the entitlement change appears in the governance trail", %{conn: conn} do
      # The acceptance criterion "every entitlement change is visible in the
      # governance audit trail". The rows exist regardless; this asserts something
      # actually surfaces them.
      stub_subscription()
      u = member()
      t = tier()
      m = membership(u, t)

      event = checkout_event(m)
      assert post_event(conn, event).status == 200
      KilnCMS.DataCase.drain_oban()

      assert [entry] = KilnCMS.Governance.entitlement_index(default_org_id())

      assert entry.kind == :activated
      assert entry.to_status == :active
      assert entry.added == [@gated]
      assert entry.removed == []
      assert entry.provider_event_id == event["id"]
      assert entry.member == to_string(u.email)
      assert entry.tier == t.name
      # No human caused it, so no actor — the provenance is the provider event.
      refute entry.actor
    end

    test "the trail is scoped to the requesting site", %{conn: conn} do
      stub_subscription()
      u = member()
      m = membership(u, tier())

      assert post_event(conn, checkout_event(m)).status == 200
      KilnCMS.DataCase.drain_oban()

      other =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Other",
          slug: "other-#{System.unique_integer([:positive])}"
        })

      assert KilnCMS.Governance.entitlement_index(other.id) == []
    end
  end

  describe "events that write nothing" do
    test "an unhandled event type is acked without a row", %{conn: conn} do
      event = %{
        "id" => "evt_unhandled",
        "type" => "customer.updated",
        "data" => %{"object" => %{}}
      }

      assert post_event(conn, event).status == 200
      assert event_rows() == []
    end

    test "an unresolvable event is recorded and ignored", %{conn: conn} do
      event = %{
        "id" => "evt_orphan",
        "type" => "customer.subscription.deleted",
        "data" => %{
          "object" => %{
            "object" => "subscription",
            "id" => "sub_nobody",
            "customer" => "cus_nobody"
          }
        }
      }

      assert post_event(conn, event).status == 200
      KilnCMS.DataCase.drain_oban()

      [row] = event_rows()
      assert row.status == :ignored
    end

    test "a non-subscription checkout is ignored", %{conn: conn} do
      m = membership(member(), tier())

      event =
        m
        |> checkout_event()
        |> put_in(["data", "object", "mode"], "payment")

      assert post_event(conn, event).status == 200
      KilnCMS.DataCase.drain_oban()

      [row] = event_rows()
      assert row.status == :ignored
    end

    test "metadata naming another user's membership is refused", %{conn: conn} do
      # A signature-verified event whose metadata disagrees with our own row is a
      # bug or an attack; it must not write.
      stub_subscription()
      victim = member()
      m = membership(victim, tier())

      event =
        m
        |> checkout_event()
        |> put_in(["data", "object", "metadata", "user_id"], Ash.UUID.generate())

      assert post_event(conn, event).status == 200
      KilnCMS.DataCase.drain_oban()

      assert audiences_of(victim.id) == []
      [row] = event_rows()
      assert row.status == :ignored
    end
  end

  describe "unconfigured instance" do
    test "the route 404s when billing has no credentials", %{conn: conn} do
      {:ok, settings} =
        Billing.clear_billing_credentials(Billing.ensure_settings!(), authorize?: false)

      refute settings.secret_key_encrypted

      m = membership(member(), tier())

      # 404 rather than 503: an unconfigured instance shouldn't confirm the route
      # exists at all.
      assert post_event(conn, checkout_event(m)).status == 404
      assert event_rows() == []
    end
  end
end
