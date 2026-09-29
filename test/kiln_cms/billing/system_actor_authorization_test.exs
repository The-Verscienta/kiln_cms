defmodule KilnCMS.Billing.SystemActorAuthorizationTest do
  @moduledoc """
  The billing pipeline as the billing system actor (#1659, batch 7).

  The webhook worker, the resolution ladder behind it, the membership
  transition's trail row and the entitlement recompute's reads used to run
  `authorize?: false`. They now run as `KilnCMS.Billing.system/0`. Each grant
  here is paired with a refusal.

  Every migrated read that backs a decision is tested with the grant taken
  away (`Billing.with_actor/2`). A refused read is FILTERED, so it answers
  `[]` or `nil`, and in billing those answers are dangerous: `[]` memberships
  recomputes a paying member to "entitled to nothing", and a `nil` event or
  membership consumes a payment event as "gone" or "unresolvable". Each test
  asserts an error and unchanged state, never an empty answer.
  """
  use KilnCMS.DataCase, async: true

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.Entitlements
  alias KilnCMS.Billing.Subscriptions
  alias KilnCMS.Billing.WebhookEvent
  alias KilnCMS.Billing.Webhooks
  alias KilnCMS.Billing.WebhookWorker
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())

  defp uniq, do: System.unique_integer([:positive])
  defp org_id, do: Accounts.default_org_id()

  defp user(role \\ :viewer) do
    Ash.Seed.seed!(User, %{
      email: "sab7-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp tier do
    Ash.Seed.seed!(Billing.MembershipTier, %{
      org_id: org_id(),
      name: "Tier #{uniq()}",
      slug: "sab7-tier-#{uniq()}",
      audience: @gated,
      provider_price_id: "price_#{uniq()}"
    })
  end

  defp membership(attrs \\ %{}) do
    Ash.Seed.seed!(
      Billing.Membership,
      Map.merge(
        %{
          org_id: org_id(),
          user_id: user().id,
          tier_id: tier().id,
          status: :active,
          provider_subscription_id: "sub_#{uniq()}",
          provider_customer_id: "cus_#{uniq()}"
        },
        attrs
      )
    )
  end

  defp event_row(payload \\ %{"type" => "ping"}) do
    Billing.receive_webhook_event!(
      %{
        provider: :stripe,
        provider_event_id: "evt_#{uniq()}",
        type: payload["type"],
        payload: payload
      },
      authorize?: false
    )
  end

  defp reload_event(row), do: Ash.get!(WebhookEvent, row.id, authorize?: false)

  defp reload_membership(m),
    do: Billing.get_membership!(m.id, authorize?: false, tenant: m.org_id)

  defp audiences_of(user_id) do
    {:ok, user} = Accounts.get_user(user_id, authorize?: false)
    user.audiences
  end

  defp by_metadata(m),
    do: %{
      "data" => %{"object" => %{"metadata" => %{"membership_id" => m.id, "org_id" => m.org_id}}}
    }

  defp by_subscription(m),
    do: %{"data" => %{"object" => %{"subscription" => m.provider_subscription_id}}}

  defp by_customer(m), do: %{"data" => %{"object" => %{"customer" => m.provider_customer_id}}}

  describe "WebhookEvent: the worker's grants" do
    test "the system actor reads an event by id; no person but a platform admin does" do
      row = event_row()

      assert {:ok, %{id: id}} =
               Billing.get_webhook_event(row.id,
                 actor: Billing.system(),
                 authorize_with: :error
               )

      assert id == row.id

      assert {:error, %Ash.Error.Forbidden{}} =
               Billing.get_webhook_event(row.id, actor: user(:editor), authorize_with: :error)
    end

    test "the system actor may not list, look up by provider id, or sweep events" do
      row = event_row()
      sys = Billing.system()

      assert {:error, %Ash.Error.Forbidden{}} =
               Billing.recent_webhook_events(actor: sys, authorize_with: :error)

      assert {:error, %Ash.Error.Forbidden{}} =
               Billing.webhook_event_by_event_id(row.provider_event_id,
                 actor: sys,
                 authorize_with: :error
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Billing.purgeable_webhook_events(DateTime.utc_now(),
                 actor: sys,
                 authorize_with: :error
               )
    end

    test "the system actor claims and settles an event" do
      sys = Billing.system()

      claimed = Billing.claim_webhook_event!(event_row(), actor: sys)
      assert claimed.status == :processing

      assert Billing.mark_webhook_event_ignored!(claimed, %{error: "x"}, actor: sys).status ==
               :ignored

      claimed = Billing.claim_webhook_event!(event_row(), actor: sys)

      assert Billing.mark_webhook_event_failed!(claimed, %{error: "x"}, actor: sys).status ==
               :failed

      claimed = Billing.claim_webhook_event!(event_row(), actor: sys)
      assert Billing.mark_webhook_event_processed!(claimed, %{}, actor: sys).status == :processed
    end

    test "the system actor may not record or destroy an event" do
      sys = Billing.system()

      assert {:error, %Ash.Error.Forbidden{}} =
               Billing.receive_webhook_event(
                 %{
                   provider: :stripe,
                   provider_event_id: "evt_#{uniq()}",
                   type: "ping",
                   payload: %{}
                 },
                 actor: sys
               )

      row = event_row()
      assert {:error, %Ash.Error.Forbidden{}} = Billing.destroy_webhook_event(row, actor: sys)
      assert reload_event(row)
    end

    test "no person may claim or settle an event, platform admin included" do
      admin = user(:admin)
      row = event_row()

      assert {:error, %Ash.Error.Forbidden{}} = Billing.claim_webhook_event(row, actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               Billing.mark_webhook_event_processed(row, %{}, actor: admin)

      assert reload_event(row).status == :received
    end
  end

  describe "WebhookWorker fails closed" do
    test "a refused event read retries; it does not cancel the event as gone" do
      row = event_row()

      log =
        capture_log(fn ->
          assert {:error, %Ash.Error.Forbidden{}} =
                   Billing.with_actor(nil, fn ->
                     WebhookWorker.perform(%Oban.Job{args: %{"webhook_event_id" => row.id}})
                   end)
        end)

      # The refusal is the READ's: had the read gone through, the claim after
      # it would have been refused instead, and that says so in the log.
      refute log =~ "claim refused"
      assert reload_event(row).status == :received
    end

    test "a refused claim retries; it is not reported as already claimed" do
      # A platform admin may read the event but not claim it, which isolates
      # the claim's refusal from the read before it.
      row = event_row()

      log =
        capture_log(fn ->
          assert {:error, %Ash.Error.Forbidden{}} =
                   Billing.with_actor(user(:admin), fn ->
                     WebhookWorker.perform(%Oban.Job{args: %{"webhook_event_id" => row.id}})
                   end)
        end)

      assert log =~ "claim refused"
      assert reload_event(row).status == :received
    end

    test "as the system actor it processes the event end to end" do
      m = membership(%{status: :incomplete})

      payload = %{
        "id" => "evt_#{uniq()}",
        "type" => "customer.subscription.updated",
        "data" => %{
          "object" => %{
            "object" => "subscription",
            "id" => m.provider_subscription_id,
            "status" => "active",
            "customer" => m.provider_customer_id
          }
        }
      }

      row = event_row(payload)

      assert :ok = WebhookWorker.perform(%Oban.Job{args: %{"webhook_event_id" => row.id}})
      assert reload_event(row).status == :processed
      assert reload_membership(m).status == :active
      assert audiences_of(m.user_id) == [@gated]
    end
  end

  describe "Webhooks.resolve/1 fails closed" do
    test "every rung resolves as the system actor" do
      m = membership()

      for event <- [by_metadata(m), by_subscription(m), by_customer(m)] do
        assert {:ok, %{id: id}} = Webhooks.resolve(event)
        assert id == m.id
      end
    end

    test "a refused metadata read is an error, not :unresolvable" do
      m = membership()

      assert {:error, %Ash.Error.Forbidden{}} =
               Billing.with_actor(nil, fn -> Webhooks.resolve(by_metadata(m)) end)
    end

    test "a refused subscription-id read is an error, not :unresolvable" do
      m = membership()

      assert {:error, %Ash.Error.Forbidden{}} =
               Billing.with_actor(nil, fn -> Webhooks.resolve(by_subscription(m)) end)
    end

    test "a refused customer-id read is an error, not :unresolvable" do
      m = membership()

      assert {:error, %Ash.Error.Forbidden{}} =
               Billing.with_actor(nil, fn -> Webhooks.resolve(by_customer(m)) end)
    end

    test "a malformed id still resolves to nothing rather than retrying" do
      assert {:ignored, :unresolvable} =
               Webhooks.resolve(%{
                 "data" => %{"object" => %{"metadata" => %{"membership_id" => "not-a-uuid"}}}
               })
    end
  end

  describe "the membership transition" do
    test "a refused provider-state write is an error and changes nothing" do
      # The member resolves their own membership (the self-read grant) but may
      # not apply provider state, which is closed to every person.
      m = membership(%{status: :incomplete})
      member = Accounts.get_user!(m.user_id, authorize?: false)

      # Positive control: the member really does resolve it, so the refusal
      # below is the write's, not the read's.
      assert {:ok, %{id: resolved}} =
               Billing.with_actor(member, fn -> Webhooks.resolve(by_subscription(m)) end)

      assert resolved == m.id

      event = %{
        "id" => "evt_#{uniq()}",
        "type" => "customer.subscription.updated",
        "data" => %{
          "object" => %{
            "object" => "subscription",
            "id" => m.provider_subscription_id,
            "status" => "active"
          }
        }
      }

      assert {:error, %Ash.Error.Forbidden{errors: errors}} =
               Billing.with_actor(member, fn -> Subscriptions.apply(event) end)

      # Refused on `Membership` itself. Had the write gone through, the trail
      # append inside its transition would have been refused on
      # `MembershipEvent` instead (the member is `system/0` here too).
      assert Enum.any?(
               errors,
               &match?(%Ash.Error.Forbidden.Policy{resource: Billing.Membership}, &1)
             )

      assert reload_membership(m).status == :incomplete
    end

    test "a refused trail append rolls the transition back" do
      # The comp itself is the admin's; the trail row is appended as
      # `Billing.system/0`. Answering an admin there (a person, whom
      # `MembershipEvent` refuses) must undo the comp, not commit it untrailed.
      admin = user(:admin)
      member = user()
      tier = tier()

      assert {:error, _error} =
               Billing.with_actor(admin, fn ->
                 Billing.comp_membership(%{user_id: member.id, tier_id: tier.id},
                   actor: admin,
                   tenant: org_id()
                 )
               end)

      assert Billing.memberships_for_export!(member.id, authorize?: false) == []
      assert audiences_of(member.id) == []

      # The same comp with the grant in place succeeds, with its trail row.
      comped =
        Billing.comp_membership!(%{user_id: member.id, tier_id: tier.id},
          actor: admin,
          tenant: org_id()
        )

      assert [_event] = Billing.membership_events!(comped.id, authorize?: false, tenant: org_id())
    end
  end

  describe "Entitlements.recompute/1 fails closed" do
    test "a refused membership read aborts instead of revoking a paying member" do
      m = membership()
      assert {:ok, %{after: [@gated]}} = Entitlements.recompute(m.user_id)
      assert audiences_of(m.user_id) == [@gated]

      assert {:error, %Ash.Error.Forbidden{}} =
               Billing.with_actor(nil, fn -> Entitlements.recompute(m.user_id) end)

      assert audiences_of(m.user_id) == [@gated]

      assert [%{audiences: [@gated]}] =
               Accounts.list_memberships_for_user!(m.user_id, authorize?: false)
               |> Enum.filter(&(&1.organization_id == m.org_id))
    end
  end
end
