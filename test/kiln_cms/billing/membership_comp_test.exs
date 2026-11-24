defmodule KilnCMS.Billing.MembershipCompTest do
  @moduledoc """
  `Membership` `:comp` — an admin's complimentary membership.

  A comp over a row the provider may still bill is refused (#3156): a comped
  row ignores every provider event, so the provider would go on charging a
  member whose cancellation never reached the row. The guard is the action's
  `upsert_condition`, so these call `Billing.comp_membership` directly.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  @moduletag :capture_log

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.AccountErased
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.Entitlements
  alias KilnCMS.Billing.Errors.StillBilled
  alias KilnCMS.Billing.Membership
  alias KilnCMS.Billing.MembershipWebhookWorker
  alias KilnCMS.Billing.Subscriptions
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())
  @period_end ~U[2027-03-05 00:00:00.000000Z]

  defp uniq, do: System.unique_integer([:positive])
  defp org_id, do: Accounts.default_org_id()

  defp user(role \\ :viewer, extra \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "comp-#{role}-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        extra
      )
    )
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

  defp seed(user, tier, status, extra \\ %{}) do
    Ash.Seed.seed!(
      Membership,
      Map.merge(
        %{org_id: org_id(), user_id: user.id, tier_id: tier.id, status: status},
        extra
      )
    )
  end

  # A row the provider is billing: a subscription, a customer, a period.
  defp billed(status) do
    %{
      status: status,
      provider_subscription_id: "sub_1",
      provider_customer_id: "cus_1",
      current_period_end: @period_end,
      cancel_at_period_end: false
    }
  end

  defp comp(member, tier, actor, note \\ "press pass") do
    Billing.comp_membership(%{user_id: member.id, tier_id: tier.id, note: note},
      actor: actor,
      tenant: org_id()
    )
  end

  defp reload(m), do: Billing.get_membership!(m.id, authorize?: false, tenant: org_id())

  defp events(membership_id),
    do: Billing.membership_events!(membership_id, authorize?: false, tenant: org_id())

  defp audiences_of(user_id) do
    {:ok, user} = Accounts.get_user(user_id, authorize?: false)
    user.audiences
  end

  defp deleted_event(m, sub_id) do
    %{
      "id" => "evt_#{uniq()}",
      "type" => "customer.subscription.deleted",
      "created" => DateTime.to_unix(DateTime.utc_now()),
      "data" => %{
        "object" => %{
          "object" => "subscription",
          "id" => sub_id,
          "customer" => "cus_1",
          "status" => "canceled",
          "metadata" => %{"membership_id" => m.id, "org_id" => m.org_id, "user_id" => m.user_id}
        }
      }
    }
  end

  describe "a row the provider may still bill is refused" do
    for status <- [:active, :past_due, :incomplete] do
      test "#{status} holding a subscription" do
        member = user()
        t = tier()
        row = seed(member, t, unquote(status), billed(unquote(status)))
        {:ok, _} = Entitlements.recompute(member.id)
        audiences_before = audiences_of(member.id)

        assert {:error, %Ash.Error.Invalid{errors: errors}} = comp(member, t, user(:admin))
        assert [%StillBilled{field: :status} = error] = errors
        assert Exception.message(error) =~ "cancel the subscription at the provider"

        stored = reload(row)
        assert stored.status == unquote(status)
        assert stored.note == nil
        assert stored.provider_subscription_id == "sub_1"
        assert stored.provider_customer_id == "cus_1"
        assert stored.current_period_end == @period_end
        assert events(row.id) == []
        refute_enqueued worker: MembershipWebhookWorker
        assert audiences_of(member.id) == audiences_before
      end
    end
  end

  describe "a row the provider does not bill is comped" do
    test "no row yet" do
      member = user()
      t = tier()

      assert {:ok, comped} = comp(member, t, user(:admin))

      assert comped.status == :comped
      assert comped.note == "press pass"
      assert [_event] = events(comped.id)
      assert @gated in audiences_of(member.id)
    end

    test ":canceled holding the old subscription drops it and keeps the customer" do
      member = user()
      t = tier()

      row =
        seed(member, t, :canceled, %{
          billed(:canceled)
          | cancel_at_period_end: true
        })

      assert {:ok, comped} = comp(member, t, user(:admin))

      assert comped.id == row.id
      stored = reload(row)
      assert stored.status == :comped
      assert stored.provider_subscription_id == nil
      assert stored.current_period_end == nil
      assert stored.cancel_at_period_end == false
      assert stored.provider_customer_id == "cus_1"
      assert [_event] = events(row.id)
    end

    test ":incomplete with no subscription" do
      member = user()
      t = tier()
      row = seed(member, t, :incomplete, %{provider_customer_id: "cus_1"})

      assert {:ok, comped} = comp(member, t, user(:admin))

      assert comped.id == row.id
      assert reload(row).status == :comped
      assert [_event] = events(row.id)
    end

    test ":active with no subscription" do
      member = user()
      t = tier()
      row = seed(member, t, :active)

      assert {:ok, comped} = comp(member, t, user(:admin))

      assert comped.id == row.id
      assert reload(row).status == :comped
      assert [_event] = events(row.id)
    end

    test ":comped takes the new note" do
      # The trail count is not asserted: a comp over a comped row records a
      # transition from the create's default status, which predates #3156.
      member = user()
      t = tier()
      row = seed(member, t, :comped, %{note: "first"})

      assert {:ok, comped} = comp(member, t, user(:admin), "second")

      assert comped.id == row.id
      stored = reload(row)
      assert stored.status == :comped
      assert stored.note == "second"
    end
  end

  test "once the provider's cancellation arrives, the comp goes through" do
    member = user()
    t = tier()
    row = seed(member, t, :active, billed(:active))
    admin = user(:admin)

    assert {:error, %Ash.Error.Invalid{errors: [%StillBilled{}]}} = comp(member, t, admin)

    assert {:ok, %{status: :canceled}} = Subscriptions.apply(deleted_event(row, "sub_1"))

    assert {:ok, comped} = comp(member, t, admin)
    assert comped.id == row.id
    assert reload(row).status == :comped
    assert reload(row).provider_subscription_id == nil
    assert @gated in audiences_of(member.id)
  end

  describe "who may comp" do
    for role <- [:editor, :viewer] do
      test "an #{role} is refused" do
        member = user()
        t = tier()

        assert {:error, %Ash.Error.Forbidden{}} = comp(member, t, user(unquote(role)))

        assert Billing.memberships_for_export!(member.id, authorize?: false) == []
      end
    end

    test "the member themselves is refused" do
      member = user()
      t = tier()

      assert {:error, %Ash.Error.Forbidden{}} = comp(member, t, member)
      assert Billing.memberships_for_export!(member.id, authorize?: false) == []
    end

    test "an erased account is refused as erased, not as billed" do
      # The row is one the comp guard would refuse as billed too, so this
      # pins which refusal wins: the account check comes first.
      erased = user(:viewer, %{anonymized_at: DateTime.utc_now()})
      t = tier()
      row = seed(erased, t, :active, billed(:active))

      assert {:error, %Ash.Error.Invalid{errors: errors}} = comp(erased, t, user(:admin))
      assert Enum.any?(errors, &match?(%AccountErased{}, &1))
      refute Enum.any?(errors, &match?(%StillBilled{}, &1))

      stored = reload(row)
      assert stored.status == :active
      assert stored.provider_subscription_id == "sub_1"
    end
  end
end
