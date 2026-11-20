defmodule KilnCMS.Billing.MembershipStartTest do
  @moduledoc """
  `Membership` `:start` — the row created before redirecting to checkout.

  A re-click on "join" must never demote a live membership (#2747): the guard
  is the action's `upsert_condition`, so these call `Billing.start_membership`
  directly, with no controller in front of it.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.Entitlements
  alias KilnCMS.Billing.Membership
  alias KilnCMS.Billing.MembershipEvent
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())

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

  defp start(user, tier) do
    Billing.start_membership(%{user_id: user.id, tier_id: tier.id},
      actor: user,
      tenant: org_id()
    )
  end

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
      row = seed(u, t, unquote(status), %{provider_customer_id: "cus_1"})
      {:ok, _} = Entitlements.recompute(u.id)
      before_events = events(row.id)

      assert {:ok, returned} = start(u, t)

      assert returned.id == row.id
      assert returned.status == unquote(status)
      assert returned.__metadata__[:upsert_skipped]

      assert {:ok, [stored]} =
               Billing.memberships_for_user(u.id, authorize?: false, tenant: org_id())

      assert stored.status == unquote(status)
      assert stored.provider_customer_id == "cus_1"
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
  end

  test "no row yet: creates an :incomplete one" do
    u = user()
    t = tier()

    assert {:ok, started} = start(u, t)
    assert started.status == :incomplete
  end
end
