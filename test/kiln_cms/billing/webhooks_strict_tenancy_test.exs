defmodule KilnCMS.Billing.WebhooksStrictTenancyTest do
  @moduledoc """
  The customer rung of the resolution ladder under strict tenancy (#2754).

  Production runs strict tenancy, where a tenant-less read of a tenant-scoped
  resource raises `TenantRequired`. Failed reads are now retried rather than
  ignored, so a rung that quietly depended on fail-open tenancy would turn into
  eight retries per event. Runs only on the strict CI leg (`KILN_STRICT_TEST=1`).
  """
  use KilnCMS.DataCase, async: true

  @moduletag :strict_tenancy

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.Webhooks
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())

  defp uniq, do: System.unique_integer([:positive])

  defp user do
    Ash.Seed.seed!(User, %{
      email: "strict-hook-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :viewer
    })
  end

  defp tier(price_id) do
    Ash.Seed.seed!(Billing.MembershipTier, %{
      org_id: Accounts.default_org_id(),
      name: "Tier #{uniq()}",
      slug: "strict-hook-tier-#{uniq()}",
      audience: @gated,
      provider_price_id: price_id
    })
  end

  defp membership(attrs) do
    Ash.Seed.seed!(
      Billing.Membership,
      Map.merge(%{org_id: Accounts.default_org_id(), status: :active}, attrs)
    )
  end

  defp event(object), do: %{"data" => %{"object" => object}}

  test "a sole membership resolves by customer id" do
    cus = "cus_#{uniq()}"

    m =
      membership(%{
        user_id: user().id,
        tier_id: tier("price_#{uniq()}").id,
        provider_customer_id: cus
      })

    assert {:ok, %{id: id}} = Webhooks.resolve(event(%{"customer" => cus}))
    assert id == m.id
  end

  test "a customer holding two tiers resolves by the event's price id" do
    cus = "cus_#{uniq()}"
    user = user()
    price = "price_#{uniq()}"

    wanted =
      membership(%{user_id: user.id, tier_id: tier(price).id, provider_customer_id: cus})

    membership(%{
      user_id: user.id,
      tier_id: tier("price_#{uniq()}").id,
      provider_customer_id: cus
    })

    assert {:ok, %{id: id}} =
             Webhooks.resolve(event(%{"customer" => cus, "plan" => %{"id" => price}}))

    assert id == wanted.id

    assert {:ignored, :unresolvable} = Webhooks.resolve(event(%{"customer" => cus}))
  end
end
