defmodule KilnCMS.Billing.RestartLateEventsTest do
  @moduledoc """
  A restarted membership and the late events of the subscription it had
  (#3157).

  A restart (`Membership.:start` over a `:canceled` or `:incomplete` row)
  drops the old subscription's id and keeps the ordering stamp, so
  `KilnCMS.Billing.EventGuard` ignores a terminal event for the old
  subscription as `:other_subscription` and an older one as `:out_of_order`.
  A new subscription still takes the row over. Driven through
  `Subscriptions.apply/1`, the webhook worker's own entry point.

  `async: false`: the checkout case selects `KilnCMS.StubBillingProvider`
  through `Application.put_env`, which is global to the node.
  """
  use KilnCMS.DataCase, async: false

  @moduletag :capture_log

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.Membership
  alias KilnCMS.Billing.Subscriptions
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())
  @t 1_800_000_000

  defp uniq, do: System.unique_integer([:positive])
  defp org_id, do: Accounts.default_org_id()

  defp user(role \\ :viewer) do
    Ash.Seed.seed!(User, %{
      email: "restart-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp tier do
    Billing.create_tier!(
      %{
        name: "Supporter",
        slug: "supporter-#{uniq()}",
        audience: @gated,
        provider_price_id: "price_#{uniq()}"
      },
      authorize?: false,
      tenant: org_id()
    )
  end

  # A member whose subscription "sub_a" was canceled; the last event applied
  # was created at `stamp`.
  defp canceled_member(stamp) do
    member = user()
    t = tier()

    row =
      Ash.Seed.seed!(Membership, %{
        org_id: org_id(),
        user_id: member.id,
        tier_id: t.id,
        status: :canceled,
        provider_subscription_id: "sub_a",
        provider_customer_id: "cus_1",
        current_period_end: DateTime.from_unix!(@t + 3_600),
        cancel_at_period_end: true,
        last_provider_event_at: stamp,
        canceled_at: DateTime.utc_now()
      })

    {member, t, row}
  end

  defp restart(member, t) do
    Billing.start_membership!(%{user_id: member.id, tier_id: t.id},
      actor: member,
      tenant: org_id()
    )
  end

  defp reload(m), do: Billing.get_membership!(m.id, authorize?: false, tenant: org_id())

  defp metadata(m), do: %{"membership_id" => m.id, "org_id" => m.org_id, "user_id" => m.user_id}

  defp sub_event(type, m, sub_id, created, status) do
    %{
      "id" => "evt_#{uniq()}",
      "type" => type,
      "created" => created,
      "data" => %{
        "object" => %{
          "object" => "subscription",
          "id" => sub_id,
          "customer" => "cus_1",
          "status" => status,
          "metadata" => metadata(m)
        }
      }
    }
  end

  defp updated(m, sub_id, status, created),
    do: sub_event("customer.subscription.updated", m, sub_id, created, status)

  defp deleted(m, sub_id, created),
    do: sub_event("customer.subscription.deleted", m, sub_id, created, "canceled")

  defp stamp(seconds), do: DateTime.from_unix!(seconds)

  test "a terminal event for the old subscription, created after the stamp, is ignored" do
    {member, t, row} = canceled_member(stamp(@t))
    restart(member, t)

    assert {:ignored, :other_subscription} = Subscriptions.apply(deleted(row, "sub_a", @t + 100))

    assert reload(row).status == :incomplete
  end

  test "an older event for the old subscription is out of order" do
    {member, t, row} = canceled_member(stamp(@t))
    restart(member, t)

    assert {:ignored, :out_of_order} =
             Subscriptions.apply(updated(row, "sub_a", "active", @t - 100))

    assert reload(row).status == :incomplete
  end

  test "a new subscription takes the row over, and the old one's events stay out" do
    {member, t, row} = canceled_member(stamp(@t))
    restart(member, t)

    assert {:ok, %{status: :active}} =
             Subscriptions.apply(updated(row, "sub_b", "active", @t + 100))

    assert reload(row).provider_subscription_id == "sub_b"

    assert {:ignored, :other_subscription} =
             Subscriptions.apply(updated(row, "sub_a", "past_due", @t + 200))

    assert {:ignored, :other_subscription} = Subscriptions.apply(deleted(row, "sub_a", @t + 300))

    stored = reload(row)
    assert stored.status == :active
    assert stored.provider_subscription_id == "sub_b"
  end

  test "the old subscription no longer resolves to the restarted row" do
    {member, t, _row} = canceled_member(stamp(@t))
    restart(member, t)

    assert {:ok, nil} =
             Billing.membership_by_subscription("sub_a",
               authorize?: false,
               not_found_error?: false
             )
  end

  describe "checkout for a new subscription" do
    setup do
      # Merged into (and restored over) the existing key: it also carries
      # config/test.exs's `req_options` Req.Test plug.
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
        Billing.store_billing_secret(settings, :webhook_secret, "whsec_abc", authorize?: false)

      :ok
    end

    test "applies, on the customer the row kept" do
      {member, t, row} = canceled_member(stamp(@t))
      restart(member, t)

      event = %{
        "id" => "evt_#{uniq()}",
        "type" => "checkout.session.completed",
        "created" => @t + 100,
        "data" => %{
          "object" => %{
            "id" => "cs_#{uniq()}",
            "mode" => "subscription",
            "subscription" => "sub_b",
            "customer" => "cus_1",
            "metadata" => metadata(row)
          }
        }
      }

      assert {:ok, %{status: :active}} = Subscriptions.apply(event)

      stored = reload(row)
      assert stored.provider_subscription_id == "sub_b"
      assert stored.provider_customer_id == "cus_1"
      assert stored.cancel_at_period_end == false
    end
  end

  test "an uncomp stamps a row that had no provider event, so a restart is protected" do
    # A row that never had an event stamped (pre-#2749, say) is comped and
    # uncomped, then restarted. A late event for the subscription it had
    # before the comp is out of order rather than reviving the row.
    {member, t, row} = canceled_member(nil)
    admin = user(:admin)

    comped =
      Billing.comp_membership!(%{user_id: member.id, tier_id: t.id},
        actor: admin,
        tenant: org_id()
      )

    before_uncomp = DateTime.to_unix(DateTime.utc_now()) - 3_600
    Billing.uncomp_membership!(comped, actor: admin, tenant: org_id())

    uncomped = reload(row)
    assert uncomped.status == :canceled
    assert %DateTime{microsecond: {0, _}} = uncomped.last_provider_event_at

    restart(member, t)

    assert {:ignored, :out_of_order} =
             Subscriptions.apply(updated(row, "sub_a", "active", before_uncomp))

    assert reload(row).status == :incomplete
  end

  test "an uncomp keeps a stamp the provider set" do
    {member, t, row} = canceled_member(stamp(@t))
    admin = user(:admin)

    comped =
      Billing.comp_membership!(%{user_id: member.id, tier_id: t.id},
        actor: admin,
        tenant: org_id()
      )

    Billing.uncomp_membership!(comped, actor: admin, tenant: org_id())

    assert DateTime.compare(reload(row).last_provider_event_at, stamp(@t)) == :eq
  end
end
