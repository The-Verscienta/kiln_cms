defmodule KilnCMS.Billing.WebhookResolveErrorsTest do
  @moduledoc """
  What the resolution ladder does with a lookup that fails and with metadata
  that contradicts our own row (#2754).

    * A failed read that is not the event's fault (a database fault, not a
      refusal) must come back as `{:error, _}` so the worker marks the event
      `:failed` and Oban retries. It used to be flattened to `{:ignored, _}`,
      which is terminal and purgeable: the payment event was dropped.
    * A metadata mismatch halts the ladder instead of falling through to an
      identifier that could name a different row.
    * A malformed identifier in the payload is still ignored (that case lives in
      `KilnCMS.Billing.WebhooksTest`).

  The fault is real, not stubbed: `SET LOCAL search_path` points the read at a
  schema holding a view with no usable columns for the table under test, so
  Postgres rejects the query and Ash returns `Ash.Error.Unknown`. `LOCAL` and the
  schema both die with the sandbox transaction. Only the table named is broken;
  everything else (events, users) still resolves through `public`.
  """
  use KilnCMS.DataCase, async: true

  @moduletag :capture_log

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.Subscriptions
  alias KilnCMS.Billing.WebhookEvent
  alias KilnCMS.Billing.Webhooks
  alias KilnCMS.Billing.WebhookWorker
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())

  defp uniq, do: System.unique_integer([:positive])
  defp org_id, do: Accounts.default_org_id()

  defp user do
    Ash.Seed.seed!(User, %{
      email: "resolve-err-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :viewer
    })
  end

  defp tier(price_id \\ nil) do
    Ash.Seed.seed!(Billing.MembershipTier, %{
      org_id: org_id(),
      name: "Tier #{uniq()}",
      slug: "resolve-err-tier-#{uniq()}",
      audience: @gated,
      provider_price_id: price_id || "price_#{uniq()}"
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

  # Make every read of `table` fail at the database, for the rest of the test.
  defp break(table) do
    schema = "kiln_broken_#{uniq()}"
    Ecto.Adapters.SQL.query!(KilnCMS.Repo, "CREATE SCHEMA #{schema}")
    Ecto.Adapters.SQL.query!(KilnCMS.Repo, "CREATE VIEW #{schema}.#{table} AS SELECT 1 AS nope")
    Ecto.Adapters.SQL.query!(KilnCMS.Repo, "SET LOCAL search_path TO #{schema}, public")
  end

  defp event(object), do: %{"data" => %{"object" => object}}

  defp stripe_event(type, object) do
    %{"id" => "evt_#{uniq()}", "type" => type, "data" => %{"object" => object}}
  end

  defp event_row(payload) do
    Billing.receive_webhook_event!(
      %{
        provider: :stripe,
        provider_event_id: payload["id"],
        type: payload["type"],
        payload: payload
      },
      authorize?: false
    )
  end

  defp reload_event(row), do: Ash.get!(WebhookEvent, row.id, authorize?: false)

  defp reload_membership(m),
    do: Billing.get_membership!(m.id, authorize?: false, tenant: m.org_id)

  describe "a failed read is an error, not :ignored" do
    test "rung 1 (metadata) with a well-formed id" do
      m = membership()
      break("billing_memberships")

      assert {:error, %Ash.Error.Unknown{}} =
               Webhooks.resolve(
                 event(%{"metadata" => %{"membership_id" => m.id, "org_id" => m.org_id}})
               )
    end

    test "rung 2 (subscription id)" do
      m = membership()
      break("billing_memberships")

      assert {:error, %Ash.Error.Unknown{}} =
               Webhooks.resolve(event(%{"subscription" => m.provider_subscription_id}))
    end

    test "rung 3 (customer id)" do
      m = membership()
      break("billing_memberships")

      assert {:error, %Ash.Error.Unknown{}} =
               Webhooks.resolve(event(%{"customer" => m.provider_customer_id}))
    end

    test "the tier lookup that disambiguates two tiers is an error, not :ambiguous_customer" do
      cus = "cus_#{uniq()}"
      user = user()
      price = "price_#{uniq()}"
      wanted_tier = tier(price)
      membership(%{user_id: user.id, tier_id: wanted_tier.id, provider_customer_id: cus})
      membership(%{user_id: user.id, provider_customer_id: cus})
      break("billing_membership_tiers")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %Ash.Error.Unknown{}} =
                   Webhooks.resolve(event(%{"customer" => cus, "plan" => %{"id" => price}}))
        end)

      refute log =~ "does not single one out"
    end

    test "org_id/1 still answers from the metadata when resolution errors" do
      m = membership()
      break("billing_memberships")
      claimed = Ecto.UUID.generate()

      assert Webhooks.org_id(
               event(%{
                 "subscription" => m.provider_subscription_id,
                 "metadata" => %{"org_id" => claimed}
               })
             ) == claimed

      assert Webhooks.org_id(event(%{"subscription" => m.provider_subscription_id})) == nil
    end
  end

  describe "a metadata mismatch halts the ladder" do
    test "a user that is not the row's owner is refused, even when the subscription id would resolve" do
      m = membership()
      other = membership()

      mismatched =
        event(%{
          "metadata" => %{
            "membership_id" => m.id,
            "org_id" => m.org_id,
            "user_id" => other.user_id
          },
          # Would resolve `other` through rung 2 and write to it.
          "subscription" => other.provider_subscription_id
        })

      assert {:ignored, :metadata_mismatch} = Webhooks.resolve(mismatched)
    end

    test "the same event without the contradiction resolves, so the halt is the mismatch's doing" do
      m = membership()

      assert {:ok, %{id: id}} =
               Webhooks.resolve(
                 event(%{
                   "metadata" => %{
                     "membership_id" => m.id,
                     "org_id" => m.org_id,
                     "user_id" => m.user_id
                   }
                 })
               )

      assert id == m.id
    end

    test "a mismatch is refused for the customer rung too" do
      m = membership()
      other = membership()

      assert {:ignored, :metadata_mismatch} =
               Webhooks.resolve(
                 event(%{
                   "metadata" => %{"membership_id" => m.id, "user_id" => other.user_id},
                   "customer" => other.provider_customer_id
                 })
               )
    end

    test "all four handled event types refuse a mismatch and write nothing" do
      m = membership(%{status: :incomplete})
      other = membership()

      metadata = %{
        "membership_id" => m.id,
        "org_id" => m.org_id,
        "user_id" => other.user_id
      }

      for {type, object} <- [
            {"checkout.session.completed",
             %{"mode" => "subscription", "subscription" => "sub_x", "metadata" => metadata}},
            {"customer.subscription.updated",
             %{"id" => "sub_x", "status" => "active", "metadata" => metadata}},
            {"customer.subscription.deleted", %{"id" => "sub_x", "metadata" => metadata}},
            {"invoice.payment_failed", %{"metadata" => metadata}}
          ] do
        assert {:ignored, :metadata_mismatch} = Subscriptions.apply(stripe_event(type, object))
      end

      assert reload_membership(m).status == :incomplete
    end
  end

  describe "Subscriptions.apply/1 propagates a resolve error from every handled type" do
    setup do
      m = membership()
      break("billing_memberships")
      %{m: m, metadata: %{"membership_id" => m.id, "org_id" => m.org_id}}
    end

    test "checkout.session.completed (complete_checkout)", ctx do
      # The provider is never reached: the error comes from the first `with` step.
      event =
        stripe_event("checkout.session.completed", %{
          "mode" => "subscription",
          "subscription" => "sub_#{uniq()}",
          "metadata" => ctx.metadata
        })

      assert {:error, %Ash.Error.Unknown{}} = Subscriptions.apply(event)
    end

    test "customer.subscription.updated", ctx do
      event =
        stripe_event("customer.subscription.updated", %{
          "id" => "sub_x",
          "status" => "active",
          "metadata" => ctx.metadata
        })

      assert {:error, %Ash.Error.Unknown{}} = Subscriptions.apply(event)
    end

    test "customer.subscription.deleted", ctx do
      event =
        stripe_event("customer.subscription.deleted", %{
          "id" => "sub_x",
          "metadata" => ctx.metadata
        })

      assert {:error, %Ash.Error.Unknown{}} = Subscriptions.apply(event)
    end

    test "invoice.payment_failed", ctx do
      event = stripe_event("invoice.payment_failed", %{"metadata" => ctx.metadata})

      assert {:error, %Ash.Error.Unknown{}} = Subscriptions.apply(event)
    end
  end

  describe "WebhookWorker" do
    test "a failed membership read marks the event :failed and returns {:error, _} for retry" do
      m = membership(%{status: :past_due})

      row =
        event_row(
          stripe_event("customer.subscription.updated", %{
            "object" => "subscription",
            "id" => m.provider_subscription_id,
            "status" => "active"
          })
        )

      break("billing_memberships")

      assert {:error, %Ash.Error.Unknown{}} =
               WebhookWorker.perform(%Oban.Job{args: %{"webhook_event_id" => row.id}})

      reloaded = reload_event(row)
      assert reloaded.status == :failed
      refute reloaded.status == :ignored
    end

    test "a metadata mismatch is acked as :ignored, not retried" do
      m = membership(%{status: :incomplete})
      other = membership()

      row =
        event_row(
          stripe_event("customer.subscription.updated", %{
            "id" => other.provider_subscription_id,
            "status" => "active",
            "metadata" => %{
              "membership_id" => m.id,
              "org_id" => m.org_id,
              "user_id" => other.user_id
            }
          })
        )

      assert :ok = WebhookWorker.perform(%Oban.Job{args: %{"webhook_event_id" => row.id}})
      assert reload_event(row).status == :ignored
      assert reload_membership(m).status == :incomplete
      assert reload_membership(other).status == :active
    end
  end
end
