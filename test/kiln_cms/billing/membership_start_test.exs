defmodule KilnCMS.Billing.MembershipStartTest do
  @moduledoc """
  `Membership` `:start` — the row created before redirecting to checkout.

  A re-click on "join" must never demote a live membership (#2747): the guard
  is the action's `upsert_condition`, so these call `Billing.start_membership`
  directly, with no controller in front of it. A restart drops the old
  subscription and keeps the provider customer (#3157).
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.RegistrationRefused
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.Entitlements
  alias KilnCMS.Billing.Membership
  alias KilnCMS.Billing.MembershipEvent
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())
  @period_end ~U[2027-03-05 00:00:00.000000Z]
  @stamp ~U[2026-11-01 12:00:00.000000Z]

  # The old subscription a row still holds: its id, customer, period, cancel
  # flag and the stamp of the last provider event applied.
  @old_subscription %{
    provider_subscription_id: "sub_a",
    provider_customer_id: "cus_1",
    current_period_end: @period_end,
    cancel_at_period_end: true,
    last_provider_event_at: @stamp
  }

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp user do
    Ash.Seed.seed!(User, %{
      email: "member-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :viewer
    })
  end

  defp tier do
    Billing.create_tier!(
      %{
        name: "Supporter",
        slug: "supporter-#{System.unique_integer([:positive])}",
        audience: @gated,
        provider_price_id: "price_#{System.unique_integer([:positive])}"
      },
      authorize?: false,
      tenant: org_id()
    )
  end

  defp seed(user, tier, status, extra \\ %{}) do
    Ash.Seed.seed!(
      Membership,
      Map.merge(
        %{org_id: org_id(), user_id: user.id, tier_id: tier.id, status: status},
        extra
      )
    )
  end

  defp start(user, tier, actor \\ nil) do
    Billing.start_membership(%{user_id: user.id, tier_id: tier.id},
      actor: actor || user,
      tenant: org_id()
    )
  end

  defp reload(m), do: Billing.get_membership!(m.id, authorize?: false, tenant: org_id())

  defp events(membership_id) do
    import Ecto.Query
    KilnCMS.Repo.all(from e in MembershipEvent, where: e.membership_id == ^membership_id)
  end

  defp audiences_of(user_id) do
    {:ok, user} = Accounts.get_user(user_id, authorize?: false)
    user.audiences
  end

  for status <- [:active, :past_due, :comped] do
    test "a live #{status} row is returned untouched, not demoted" do
      u = user()
      t = tier()
      row = seed(u, t, unquote(status), @old_subscription)
      {:ok, _} = Entitlements.recompute(u.id)
      before_events = events(row.id)

      assert {:ok, returned} = start(u, t)

      assert returned.id == row.id
      assert returned.status == unquote(status)
      assert returned.__metadata__[:upsert_skipped]

      assert {:ok, [stored]} =
               Billing.memberships_for_user(u.id, authorize?: false, tenant: org_id())

      assert stored.status == unquote(status)
      # A refused restart touches nothing, the subscription included.
      assert Map.take(stored, Map.keys(@old_subscription)) == @old_subscription
      assert events(row.id) == before_events

      {:ok, _} = Entitlements.recompute(u.id)
      assert @gated in audiences_of(u.id)
    end
  end

  for status <- [:incomplete, :canceled] do
    test "a #{status} row restarts as :incomplete" do
      u = user()
      t = tier()
      row = seed(u, t, unquote(status))

      assert {:ok, started} = start(u, t)

      assert started.id == row.id
      assert started.status == :incomplete
      refute started.__metadata__[:upsert_skipped]
    end

    test "a #{status} restart drops the old subscription and keeps the customer (#3157)" do
      u = user()
      t = tier()
      row = seed(u, t, unquote(status), @old_subscription)

      assert {:ok, started} = start(u, t)
      assert started.id == row.id

      stored = reload(row)
      assert stored.status == :incomplete
      assert stored.provider_subscription_id == nil
      assert stored.current_period_end == nil
      assert stored.cancel_at_period_end == false
      # Checkout reuses the customer, and the billing portal needs it.
      assert stored.provider_customer_id == "cus_1"
      # Kept, so an older event for the old subscription stays out of order.
      assert stored.last_provider_event_at == @stamp

      assert Billing.membership_by_subscription("sub_a",
               authorize?: false,
               not_found_error?: false
             ) ==
               {:ok, nil}
    end
  end

  test "no row yet: creates an :incomplete one" do
    u = user()
    t = tier()

    assert {:ok, started} = start(u, t)
    assert started.status == :incomplete
    assert started.provider_subscription_id == nil
    assert started.provider_customer_id == nil
    assert started.current_period_end == nil
    assert started.cancel_at_period_end == false
  end

  describe "a refused start changes nothing" do
    test "for another member" do
      u = user()
      t = tier()
      row = seed(u, t, :canceled, @old_subscription)

      assert {:error, %Ash.Error.Forbidden{}} = start(u, t, user())

      stored = reload(row)
      assert stored.status == :canceled
      assert Map.take(stored, Map.keys(@old_subscription)) == @old_subscription
    end

    test "for an account whose registration awaits approval" do
      u = user()
      t = tier()
      row = seed(u, t, :canceled, @old_subscription)

      Ash.Seed.seed!(OrgMembership, %{
        user_id: u.id,
        organization_id: org_id(),
        role: :viewer,
        status: :pending
      })

      assert {:error, error} = start(u, t)
      assert RegistrationRefused.reason(error) == :not_approved

      stored = reload(row)
      assert stored.status == :canceled
      assert Map.take(stored, Map.keys(@old_subscription)) == @old_subscription
    end
  end
end
