defmodule KilnCMS.Billing.SubscriptionsTest do
  @moduledoc """
  The provider-status → membership-status mapping, and the handled-event
  allowlist. Pure — the transition side-effects are covered end to end in
  `KilnCMSWeb.BillingWebhookControllerTest`.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Billing.Subscriptions

  describe "membership_status/1" do
    # Every provider status, so a mapping change has to be deliberate.
    for {provider_status, expected} <- [
          {"trialing", :active},
          {"active", :active},
          {"past_due", :past_due},
          # Dunning exhausted — keeping access would be indefinite free service.
          {"unpaid", :canceled},
          {"incomplete", :incomplete},
          {"incomplete_expired", :canceled},
          {"canceled", :canceled},
          # Paused is not being paid for.
          {"paused", :canceled}
        ] do
      test "#{provider_status} maps to #{expected}" do
        assert Subscriptions.membership_status(unquote(provider_status)) == unquote(expected)
      end
    end

    test "an unknown status maps to nil rather than guessing" do
      refute Subscriptions.membership_status("some_new_status")
    end
  end

  describe "handled?/1" do
    for type <- [
          "checkout.session.completed",
          "customer.subscription.updated",
          "customer.subscription.deleted",
          "invoice.payment_failed"
        ] do
      test "#{type} is handled" do
        assert Subscriptions.handled?(unquote(type))
      end
    end

    for type <- [
          # A renewal already arrives as subscription.updated with the new period.
          "invoice.paid",
          "invoice.payment_succeeded",
          # Checkout completion plus the retrieve covers this.
          "customer.subscription.created",
          "customer.updated",
          "payment_intent.succeeded"
        ] do
      test "#{type} is NOT handled" do
        refute Subscriptions.handled?(unquote(type))
      end
    end

    test "the allowlist is exactly four types" do
      # A guard against silently widening what the receiver acts on.
      assert length(Subscriptions.handled_types()) == 4
    end
  end

  describe "apply/1 guards" do
    test "an unhandled type is ignored" do
      assert {:ignored, :unhandled_type} =
               Subscriptions.apply(%{"type" => "customer.updated", "data" => %{"object" => %{}}})
    end

    test "an event with no type is ignored rather than crashing" do
      assert {:ignored, :malformed_event} = Subscriptions.apply(%{})
    end

    test "a non-subscription checkout is ignored" do
      event = %{
        "id" => "evt_1",
        "type" => "checkout.session.completed",
        "data" => %{"object" => %{"mode" => "payment"}}
      }

      assert {:ignored, :not_a_subscription} = Subscriptions.apply(event)
    end
  end
end
