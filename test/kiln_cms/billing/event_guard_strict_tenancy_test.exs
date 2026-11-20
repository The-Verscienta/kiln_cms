defmodule KilnCMS.Billing.EventGuardStrictTenancyTest do
  @moduledoc """
  The row-lock recheck of a provider event (#2749) under strict tenancy: it
  re-reads the membership, a tenant-scoped read that raises `TenantRequired`
  without the row's own org. Runs only on the strict CI leg
  (`KILN_STRICT_TEST=1`).
  """
  use KilnCMS.DataCase, async: true

  @moduletag :strict_tenancy
  @moduletag :capture_log

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.Subscriptions
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())
  @t1 1_800_000_000

  defp uniq, do: System.unique_integer([:positive])

  defp membership do
    user =
      Ash.Seed.seed!(User, %{
        email: "strict-guard-#{uniq()}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    tier =
      Ash.Seed.seed!(Billing.MembershipTier, %{
        org_id: Accounts.default_org_id(),
        name: "Tier #{uniq()}",
        slug: "strict-guard-tier-#{uniq()}",
        audience: @gated,
        provider_price_id: "price_#{uniq()}"
      })

    Ash.Seed.seed!(Billing.Membership, %{
      org_id: Accounts.default_org_id(),
      user_id: user.id,
      tier_id: tier.id,
      status: :active,
      provider_subscription_id: "sub_a"
    })
  end

  defp event(type, m, status, created) do
    %{
      "id" => "evt_#{uniq()}",
      "type" => type,
      "created" => created,
      "data" => %{
        "object" => %{
          "object" => "subscription",
          "id" => "sub_a",
          "status" => status,
          "metadata" => %{"membership_id" => m.id, "org_id" => m.org_id}
        }
      }
    }
  end

  test "the guarded write and its locked recheck run with the row's own tenant" do
    m = membership()
    stale = Billing.get_membership!(m.id, authorize?: false, tenant: m.org_id)

    assert {:ok, _} =
             Subscriptions.apply(event("customer.subscription.deleted", m, "canceled", @t1 + 10))

    assert {:ok, row} =
             Billing.apply_provider_state(
               stale,
               %{
                 status: :active,
                 last_provider_event_at: DateTime.from_unix!(@t1),
                 event_kind: :event,
                 event_subscription_id: "sub_a",
                 event_created_at: DateTime.from_unix!(@t1)
               },
               actor: Billing.system(),
               tenant: m.org_id
             )

    assert Ash.Resource.get_metadata(row, :event_ignored) == :out_of_order

    assert {:ignored, :out_of_order} =
             Subscriptions.apply(event("customer.subscription.updated", m, "active", @t1))
  end
end
