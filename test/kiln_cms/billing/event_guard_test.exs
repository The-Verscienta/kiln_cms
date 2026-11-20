defmodule KilnCMS.Billing.EventGuardTest do
  @moduledoc """
  Provider events are not applied over newer state or another subscription's
  state (#2749): the pure predicate, then `Subscriptions.apply/1` against real
  rows, then the recheck under the row lock.
  """
  use KilnCMS.DataCase, async: true

  @moduletag :capture_log

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.EventGuard
  alias KilnCMS.Billing.Subscriptions
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())
  @t1 1_800_000_000
  @t2 @t1 + 100
  @t3 @t1 + 200

  defp uniq, do: System.unique_integer([:positive])

  defp user do
    Ash.Seed.seed!(User, %{
      email: "guard-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :viewer
    })
  end

  defp tier do
    Ash.Seed.seed!(Billing.MembershipTier, %{
      org_id: Accounts.default_org_id(),
      name: "Tier #{uniq()}",
      slug: "guard-tier-#{uniq()}",
      audience: @gated,
      provider_price_id: "price_#{uniq()}"
    })
  end

  defp membership(attrs) do
    user = user()

    Ash.Seed.seed!(
      Billing.Membership,
      Map.merge(
        %{org_id: Accounts.default_org_id(), user_id: user.id, tier_id: tier().id},
        attrs
      )
    )
  end

  defp reload(m), do: Billing.get_membership!(m.id, authorize?: false, tenant: m.org_id)

  defp metadata(m) do
    %{"membership_id" => m.id, "org_id" => m.org_id, "user_id" => m.user_id}
  end

  defp sub_event(type, m, sub_id, created, attrs) do
    event = %{
      "id" => "evt_#{uniq()}",
      "type" => type,
      "data" => %{
        "object" =>
          Map.merge(
            %{
              "object" => "subscription",
              "id" => sub_id,
              "customer" => "cus_1",
              "metadata" => metadata(m)
            },
            attrs
          )
      }
    }

    if created, do: Map.put(event, "created", created), else: event
  end

  defp updated(m, sub_id, status, created),
    do: sub_event("customer.subscription.updated", m, sub_id, created, %{"status" => status})

  defp deleted(m, sub_id, created),
    do: sub_event("customer.subscription.deleted", m, sub_id, created, %{"status" => "canceled"})

  defp stamp(seconds), do: %{DateTime.from_unix!(seconds) | microsecond: {0, 6}}

  describe "EventGuard.check/2" do
    defp row(attrs),
      do:
        Map.merge(
          %{status: :active, provider_subscription_id: "sub_a", last_provider_event_at: nil},
          attrs
        )

    defp ev(attrs),
      do:
        Map.merge(
          %{kind: :event, subscription_id: "sub_a", created_at: nil, target_status: :active},
          attrs
        )

    test "a comped row ignores every provider event" do
      assert {:ignore, :comped_not_provider_managed} =
               EventGuard.check(row(%{status: :comped}), ev(%{}))
    end

    test "an entitling row ignores another subscription; a row that does not entitle accepts it" do
      other = ev(%{subscription_id: "sub_b"})
      assert {:ignore, :other_subscription} = EventGuard.check(row(%{}), other)
      assert {:ignore, :other_subscription} = EventGuard.check(row(%{status: :past_due}), other)
      assert :ok = EventGuard.check(row(%{status: :incomplete}), other)
    end

    test "a different subscription takes over a dead row only if it is newer or live" do
      dead = row(%{status: :canceled, last_provider_event_at: stamp(@t2)})
      late = ev(%{subscription_id: "sub_b", created_at: stamp(@t1)})

      # A late non-terminal event for the old subscription must not revive it.
      assert {:ignore, :other_subscription} = EventGuard.check(dead, late)

      assert {:ignore, :other_subscription} =
               EventGuard.check(dead, %{late | created_at: stamp(@t2)})

      assert {:ignore, :other_subscription} = EventGuard.check(dead, %{late | created_at: nil})

      assert {:ignore, :other_subscription} =
               EventGuard.check(%{dead | last_provider_event_at: nil}, late)

      # A genuinely newer subscription, or a live checkout, does.
      assert :ok = EventGuard.check(dead, %{late | created_at: stamp(@t3)})
      assert :ok = EventGuard.check(dead, %{late | kind: :live, created_at: nil})

      assert :ok =
               EventGuard.check(
                 row(%{status: :incomplete, last_provider_event_at: stamp(@t2)}),
                 late
               )
    end

    test "an event without a subscription id on an entitling row fails open" do
      assert :ok = EventGuard.check(row(%{}), ev(%{subscription_id: nil}))
    end

    test "a terminal event for another subscription is ignored on every row" do
      gone = ev(%{subscription_id: "sub_b", target_status: :canceled})

      for status <- [:incomplete, :canceled, :active, :past_due] do
        assert {:ignore, :other_subscription} = EventGuard.check(row(%{status: status}), gone)
      end

      assert {:ignore, :other_subscription} =
               EventGuard.check(row(%{status: :incomplete, provider_subscription_id: nil}), gone)

      assert :ok = EventGuard.check(row(%{provider_subscription_id: nil}), gone)
    end

    test "older is out of order, equal and newer apply, null accepts" do
      last = %{last_provider_event_at: stamp(@t2)}
      assert {:ignore, :out_of_order} = EventGuard.check(row(last), ev(%{created_at: stamp(@t1)}))
      assert :ok = EventGuard.check(row(last), ev(%{created_at: stamp(@t2)}))
      assert :ok = EventGuard.check(row(last), ev(%{created_at: stamp(@t3)}))
      assert :ok = EventGuard.check(row(last), ev(%{created_at: nil}))
      assert :ok = EventGuard.check(row(%{}), ev(%{created_at: stamp(@t1)}))
    end

    test "a non-terminal event at an equal stamp never revives a canceled row" do
      canceled = row(%{status: :canceled, last_provider_event_at: stamp(@t2)})

      assert {:ignore, :out_of_order} =
               EventGuard.check(canceled, ev(%{created_at: stamp(@t2)}))

      assert :ok =
               EventGuard.check(canceled, ev(%{created_at: stamp(@t2), target_status: :canceled}))

      assert :ok = EventGuard.check(canceled, ev(%{created_at: stamp(@t3)}))
    end

    test "a live state is exempt from ordering" do
      last = row(%{last_provider_event_at: stamp(@t3)})
      assert :ok = EventGuard.check(last, ev(%{kind: :live, created_at: stamp(@t1)}))
    end

    test "ordering is per subscription" do
      last = row(%{status: :incomplete, last_provider_event_at: stamp(@t2)})
      assert :ok = EventGuard.check(last, ev(%{subscription_id: "sub_b", created_at: stamp(@t1)}))
    end
  end

  describe "subscription identity" do
    test "a deleted event for an abandoned subscription leaves the paying member alone" do
      m = membership(%{status: :active, provider_subscription_id: "sub_b"})
      {:ok, _} = Billing.Entitlements.recompute(m.user_id)
      events = length(Billing.membership_events!(m.id, authorize?: false, tenant: m.org_id))

      assert {:ignored, :other_subscription} = Subscriptions.apply(deleted(m, "sub_a", @t2))

      row = reload(m)
      assert row.status == :active
      assert row.provider_subscription_id == "sub_b"
      assert audiences(m.user_id) == [@gated]

      assert length(Billing.membership_events!(m.id, authorize?: false, tenant: m.org_id)) ==
               events
    end

    test "the same subscription's events apply to an :incomplete row" do
      m = membership(%{status: :incomplete, provider_subscription_id: "sub_a"})
      assert {:ok, _} = Subscriptions.apply(updated(m, "sub_a", "active", @t1))
      assert reload(m).status == :active
    end

    test "a deleted event for another subscription never overwrites the stored id" do
      m = membership(%{status: :canceled, provider_subscription_id: "sub_b"})
      assert {:ignored, :other_subscription} = Subscriptions.apply(deleted(m, "sub_a", @t2))
      assert reload(m).provider_subscription_id == "sub_b"
    end

    test "a deleted event on a non-entitling row with no stored id is ignored" do
      m = membership(%{status: :incomplete})
      assert {:ignored, :other_subscription} = Subscriptions.apply(deleted(m, "sub_a", @t2))
      row = reload(m)
      assert row.status == :incomplete
      assert row.provider_subscription_id == nil
    end

    test "invoice.payment_failed for another subscription is ignored (basil shape)" do
      m = membership(%{status: :active, provider_subscription_id: "sub_b"})

      assert {:ignored, :other_subscription} =
               Subscriptions.apply(invoice_failed(m, basil: "sub_a"))

      assert reload(m).status == :active
    end

    test "invoice.payment_failed for the held subscription applies (both shapes)" do
      m1 = membership(%{status: :active, provider_subscription_id: "sub_b"})
      assert {:ok, _} = Subscriptions.apply(invoice_failed(m1, basil: "sub_b"))
      assert reload(m1).status == :past_due

      m2 = membership(%{status: :active, provider_subscription_id: "sub_b"})
      assert {:ok, _} = Subscriptions.apply(invoice_failed(m2, flat: "sub_b"))
      assert reload(m2).status == :past_due
    end

    test "invoice.payment_failed carrying no subscription id fails open" do
      m = membership(%{status: :active, provider_subscription_id: "sub_b"})
      assert {:ok, _} = Subscriptions.apply(invoice_failed(m, []))
      assert reload(m).status == :past_due
    end

    test "a comped row ignores provider events" do
      m = membership(%{status: :comped})

      assert {:ignored, :comped_not_provider_managed} =
               Subscriptions.apply(updated(m, "sub_a", "canceled", @t1))

      # `invoice.payment_failed` only ever demotes `:active`, so it is settled
      # before the guard is asked.
      assert {:ignored, _reason} = Subscriptions.apply(invoice_failed(m, []))

      assert reload(m).status == :comped
    end

    test "an entitling row with no stored id still takes an event (fail open)" do
      m = membership(%{status: :active})
      assert {:ok, _} = Subscriptions.apply(updated(m, "sub_a", "past_due", @t1))
      assert reload(m).status == :past_due
    end
  end

  describe "ordering" do
    test "a retried older event does not revive a canceled member" do
      m = membership(%{status: :active, provider_subscription_id: "sub_a"})
      assert {:ok, _} = Subscriptions.apply(deleted(m, "sub_a", @t2))
      assert reload(m).status == :canceled

      assert {:ignored, :out_of_order} = Subscriptions.apply(updated(m, "sub_a", "active", @t1))
      assert reload(m).status == :canceled
    end

    test "a newer event applies and advances the stamp; an ignored one does not move it" do
      m = membership(%{status: :active, provider_subscription_id: "sub_a"})
      assert {:ok, _} = Subscriptions.apply(updated(m, "sub_a", "past_due", @t2))
      assert reload(m).last_provider_event_at == stamp(@t2)

      assert {:ignored, :out_of_order} = Subscriptions.apply(updated(m, "sub_a", "active", @t1))
      assert reload(m).last_provider_event_at == stamp(@t2)

      assert {:ok, _} = Subscriptions.apply(updated(m, "sub_a", "active", @t3))
      row = reload(m)
      assert row.status == :active
      assert row.last_provider_event_at == stamp(@t3)
    end

    test "an event with no created applies, and leaves the stamp alone" do
      m =
        membership(%{
          status: :active,
          provider_subscription_id: "sub_a",
          last_provider_event_at: stamp(@t2)
        })

      assert {:ok, _} = Subscriptions.apply(updated(m, "sub_a", "past_due", nil))
      row = reload(m)
      assert row.status == :past_due
      assert row.last_provider_event_at == stamp(@t2)
    end

    test "an equal created applies, but a non-terminal one never revives a canceled row" do
      m = membership(%{status: :active, provider_subscription_id: "sub_a"})
      assert {:ok, _} = Subscriptions.apply(updated(m, "sub_a", "past_due", @t2))
      assert {:ok, _} = Subscriptions.apply(updated(m, "sub_a", "active", @t2))
      assert {:ok, _} = Subscriptions.apply(deleted(m, "sub_a", @t2))

      assert {:ignored, :out_of_order} = Subscriptions.apply(updated(m, "sub_a", "active", @t2))
      assert reload(m).status == :canceled
    end

    test "an abandoned subscription's late deletion does not block the paid one's delayed activation" do
      # The row is :incomplete, with no subscription yet or with B's.
      for stored <- [nil, "sub_b"] do
        m = membership(%{status: :incomplete, provider_subscription_id: stored})

        # A's deletion lands first and is ignored: nothing to cancel.
        assert {:ignored, :other_subscription} = Subscriptions.apply(deleted(m, "sub_a", @t2))
        assert reload(m).status == :incomplete

        # B's activation, created before A's deletion, still applies.
        assert {:ok, _} = Subscriptions.apply(updated(m, "sub_b", "active", @t1))
        row = reload(m)
        assert row.status == :active
        assert row.provider_subscription_id == "sub_b"
        assert row.last_provider_event_at == stamp(@t1)
      end
    end

    test "a late non-terminal event for the old subscription does not revive a canceled row" do
      m =
        membership(%{
          status: :canceled,
          provider_subscription_id: "sub_b",
          last_provider_event_at: stamp(@t2)
        })

      assert {:ignored, :other_subscription} =
               Subscriptions.apply(updated(m, "sub_a", "active", @t1))

      row = reload(m)
      assert row.status == :canceled
      assert row.provider_subscription_id == "sub_b"
    end

    test "a newer event for a different subscription restarts a canceled row" do
      m =
        membership(%{
          status: :canceled,
          provider_subscription_id: "sub_b",
          last_provider_event_at: stamp(@t2)
        })

      assert {:ok, _} = Subscriptions.apply(updated(m, "sub_c", "active", @t3))
      row = reload(m)
      assert row.status == :active
      assert row.provider_subscription_id == "sub_c"
    end

    test "replaying an applied event changes nothing" do
      m = membership(%{status: :active, provider_subscription_id: "sub_a"})
      event = updated(m, "sub_a", "past_due", @t2)

      assert {:ok, _} = Subscriptions.apply(event)
      first = reload(m)
      assert {:ok, _} = Subscriptions.apply(event)
      second = reload(m)

      assert second.status == first.status
      assert second.last_provider_event_at == first.last_provider_event_at
      assert second.activated_at == first.activated_at

      # Not asserted: a replay of an applied event still appends a `:reconciled`
      # audit row. The duplicate-delivery gate for the same event id is the
      # webhook event's unique identity and claim (`WebhookWorker`), not this.
    end
  end

  describe "the recheck under the row lock" do
    # A stale struct, as a worker holds it between `resolve/1` and the write,
    # with the row moved on by a concurrent event.
    defp apply_guarded(stale, attrs, guard) do
      Billing.apply_provider_state(
        stale,
        Map.merge(attrs, guard),
        actor: Billing.system(),
        tenant: stale.org_id
      )
    end

    defp guard(sub, created, kind \\ :event),
      do: %{event_kind: kind, event_subscription_id: sub, event_created_at: stamp(created)}

    test "a stale event loses to the committed newer one and is reported as ignored" do
      m = membership(%{status: :active, provider_subscription_id: "sub_a"})
      stale = reload(m)

      assert {:ok, _} = Subscriptions.apply(deleted(m, "sub_a", @t2))
      events = length(Billing.membership_events!(m.id, authorize?: false, tenant: m.org_id))

      assert {:ok, row} =
               apply_guarded(
                 stale,
                 %{status: :active, last_provider_event_at: stamp(@t1)},
                 guard("sub_a", @t1)
               )

      assert Ash.Resource.get_metadata(row, :event_ignored) == :out_of_order
      assert reload(m).status == :canceled
      assert reload(m).last_provider_event_at == stamp(@t2)
      # No audit row, no webhook for the refused write.
      assert length(Billing.membership_events!(m.id, authorize?: false, tenant: m.org_id)) ==
               events
    end

    test "an event that still applies, over a row that moved, retries rather than writing from a stale row" do
      m = membership(%{status: :active, provider_subscription_id: "sub_a"})
      stale = reload(m)
      assert {:ok, _} = Subscriptions.apply(updated(m, "sub_a", "past_due", @t1))

      assert {:error, _} =
               apply_guarded(
                 stale,
                 %{status: :active, last_provider_event_at: stamp(@t2)},
                 guard("sub_a", @t2)
               )

      assert reload(m).status == :past_due
    end

    test "a call that names no event kind is not guarded" do
      m = membership(%{status: :active, provider_subscription_id: "sub_a"})
      assert {:ok, row} = apply_guarded(reload(m), %{status: :past_due}, %{})
      assert Ash.Resource.get_metadata(row, :event_ignored) == nil
      assert reload(m).status == :past_due
    end
  end

  defp audiences(user_id) do
    {:ok, user} = Accounts.get_user(user_id, authorize?: false)
    user.audiences
  end

  defp invoice_failed(m, opts) do
    object =
      %{"object" => "invoice", "customer" => "cus_1", "metadata" => metadata(m)}
      |> then(fn o ->
        cond do
          sub = opts[:basil] ->
            Map.put(o, "parent", %{"subscription_details" => %{"subscription" => sub}})

          sub = opts[:flat] ->
            Map.put(o, "subscription", sub)

          true ->
            o
        end
      end)

    %{
      "id" => "evt_#{uniq()}",
      "type" => "invoice.payment_failed",
      "created" => @t2,
      "data" => %{"object" => object}
    }
  end
end
