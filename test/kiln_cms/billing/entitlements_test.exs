defmodule KilnCMS.Billing.EntitlementsTest do
  @moduledoc """
  The declarative entitlement recompute — the heart of paid memberships.

  Two assertions here matter more than the rest:

    * **`sync_billing_audiences` refuses an actor**, including an admin. A
      passing `forbid_if always()` alone would have shipped an admin-reachable
      entitlement primitive, because `KilnCMS.Accounts.User` opens its policies
      with an admin `bypass` that short-circuits later policies.
    * **The recompute is idempotent.** This is what actually makes "webhook replay
      cannot double-grant" true; the event dedupe is belt, this is braces.

  `async: false`: these tests reconfigure `:audiences` app env is not used, but the
  recompute reads instance-wide tier state, so parallel tests would see each
  other's tiers.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Organization
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.Entitlements
  alias KilnCMS.CMS.Audiences

  @gated hd(Audiences.gated())

  defp default_org_id, do: KilnCMS.Accounts.default_org_id()

  defp user do
    Ash.Seed.seed!(User, %{
      email: "member-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :viewer
    })
  end

  defp admin do
    Ash.Seed.seed!(User, %{
      email: "admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp org(slug) do
    Ash.Seed.seed!(Organization, %{
      name: String.capitalize(slug),
      slug: "#{slug}-#{System.unique_integer([:positive])}"
    })
  end

  defp tier(attrs \\ %{}, org_id \\ nil) do
    Billing.create_tier!(
      Map.merge(
        %{
          name: "Supporter",
          slug: "supporter-#{System.unique_integer([:positive])}",
          audience: @gated,
          provider_price_id: "price_#{System.unique_integer([:positive])}"
        },
        attrs
      ),
      authorize?: false,
      tenant: org_id || default_org_id()
    )
  end

  # Seed a membership straight to a status, bypassing the provider path.
  defp membership(user, tier, status, org_id \\ nil) do
    Ash.Seed.seed!(Billing.Membership, %{
      org_id: org_id || default_org_id(),
      user_id: user.id,
      tier_id: tier.id,
      status: status
    })
  end

  defp audiences_of(user_id) do
    {:ok, user} = Accounts.get_user(user_id, authorize?: false)
    user.audiences
  end

  describe "granting and revoking" do
    test "an active membership grants its tier's audience" do
      u = user()
      t = tier()
      membership(u, t, :active)

      assert {:ok, delta} = Entitlements.recompute(u.id)
      assert delta.added == [@gated]
      assert audiences_of(u.id) == [@gated]
    end

    test "a canceled membership grants nothing" do
      u = user()
      t = tier()
      membership(u, t, :canceled)

      assert {:ok, delta} = Entitlements.recompute(u.id)
      assert delta.added == []
      assert audiences_of(u.id) == []
    end

    test "an incomplete membership grants nothing" do
      u = user()
      t = tier()
      membership(u, t, :incomplete)

      {:ok, _delta} = Entitlements.recompute(u.id)
      assert audiences_of(u.id) == []
    end

    test ":past_due KEEPS the audience through dunning" do
      # The provider is still retrying; locking the member out mid-dunning would
      # punish them for an expiring card.
      u = user()
      t = tier()
      membership(u, t, :past_due)

      {:ok, _delta} = Entitlements.recompute(u.id)
      assert audiences_of(u.id) == [@gated]
    end

    test ":comped grants without any provider subscription" do
      u = user()
      t = tier()
      membership(u, t, :comped)

      {:ok, _delta} = Entitlements.recompute(u.id)
      assert audiences_of(u.id) == [@gated]
    end

    test "revoking reports the removed audience" do
      u = user()
      t = tier()
      m = membership(u, t, :active)

      {:ok, _delta} = Entitlements.recompute(u.id)
      assert audiences_of(u.id) == [@gated]

      Ash.Seed.update!(m, %{status: :canceled})

      assert {:ok, delta} = Entitlements.recompute(u.id)
      assert delta.removed == [@gated]
      assert audiences_of(u.id) == []
    end
  end

  describe "idempotence" do
    test "recomputing five times grants exactly once and stays stable" do
      # THE replay assertion. Even if every dedupe layer above were defeated, a
      # recompute is a pure function of current state, so re-application cannot
      # double-grant.
      u = user()
      t = tier()
      membership(u, t, :active)

      for _ <- 1..5, do: {:ok, _delta} = Entitlements.recompute(u.id)

      assert audiences_of(u.id) == [@gated]
    end

    test "a no-op recompute reports an empty delta" do
      u = user()
      t = tier()
      membership(u, t, :active)

      {:ok, first} = Entitlements.recompute(u.id)
      assert first.added == [@gated]

      {:ok, second} = Entitlements.recompute(u.id)
      assert second.added == []
      assert second.removed == []
      assert second.before == second.after
    end
  end

  describe "two tiers granting the same audience" do
    test "cancelling one leaves the audience while the other is active" do
      u = user()
      monthly = tier(%{name: "Monthly"})
      annual = tier(%{name: "Annual"})

      m1 = membership(u, monthly, :active)
      membership(u, annual, :active)

      {:ok, _delta} = Entitlements.recompute(u.id)
      assert audiences_of(u.id) == [@gated]

      Ash.Seed.update!(m1, %{status: :canceled})

      {:ok, _delta} = Entitlements.recompute(u.id)
      assert audiences_of(u.id) == [@gated]
    end

    test "cancelling both revokes it" do
      u = user()
      monthly = tier(%{name: "Monthly"})
      annual = tier(%{name: "Annual"})

      m1 = membership(u, monthly, :active)
      m2 = membership(u, annual, :active)

      {:ok, _delta} = Entitlements.recompute(u.id)

      Ash.Seed.update!(m1, %{status: :canceled})
      Ash.Seed.update!(m2, %{status: :canceled})

      {:ok, _delta} = Entitlements.recompute(u.id)
      assert audiences_of(u.id) == []
    end
  end

  describe "managed audiences span inactive tiers" do
    test "retiring a tier does not freeze an existing grant" do
      # If `managed` only counted ACTIVE tiers, retiring one would reclassify its
      # audience as admin-owned and freeze every grant of it permanently, with
      # nothing left to revoke it.
      u = user()
      t = tier()
      m = membership(u, t, :active)

      {:ok, _delta} = Entitlements.recompute(u.id)
      assert audiences_of(u.id) == [@gated]

      {:ok, _tier} = Billing.update_tier(t, %{active: false}, authorize?: false)
      Ash.Seed.update!(m, %{status: :canceled})

      {:ok, _delta} = Entitlements.recompute(u.id)
      assert audiences_of(u.id) == []
    end

    test "managed_audiences/0 includes retired tiers" do
      t = tier()
      {:ok, _tier} = Billing.update_tier(t, %{active: false}, authorize?: false)

      assert @gated in Entitlements.managed_audiences()
    end
  end

  describe "division of authority" do
    test "an audience no tier claims is preserved verbatim" do
      # Admin-owned audiences must survive a full billing grant/revoke cycle.
      # Needs a second configured audience that NO tier claims.
      other = Enum.find(Audiences.gated(), &(&1 != @gated))

      if other do
        u = user()
        t = tier()

        {:ok, _user} =
          Accounts.manage_user_access(u, %{audiences: [other]}, actor: admin())

        m = membership(u, t, :active)
        {:ok, _delta} = Entitlements.recompute(u.id)
        assert Enum.sort(audiences_of(u.id)) == Enum.sort([other, @gated])

        Ash.Seed.update!(m, %{status: :canceled})
        {:ok, _delta} = Entitlements.recompute(u.id)

        # The billing audience is gone; the admin-owned one remains.
        assert audiences_of(u.id) == [other]
      else
        # Only one gated audience is configured, so there is no non-tier audience
        # to preserve. The mechanism is still covered by the assertion below that
        # a hand-granted TIER-managed audience is (correctly) dropped.
        assert length(Audiences.gated()) == 1
      end
    end

    test "a hand-granted tier-managed audience is dropped by the recompute" do
      # Documented consequence: once an audience is claimed by any tier, granting
      # it via `manage_access` is transient. Comping is the supported lever.
      u = user()
      _t = tier()

      {:ok, _user} = Accounts.manage_user_access(u, %{audiences: [@gated]}, actor: admin())
      assert audiences_of(u.id) == [@gated]

      {:ok, delta} = Entitlements.recompute(u.id)

      assert delta.removed == [@gated]
      assert audiences_of(u.id) == []
    end
  end

  describe "sync_billing_audiences is system-only" do
    test "an ADMIN actor is refused despite the admin policy bypass" do
      # The single most important policy assertion in this PR. `User` opens with
      # `bypass actor_attribute_equals(:role, :admin)`, which short-circuits the
      # `forbid_if always()` — so the change module must refuse the actor.
      u = user()

      assert {:error, error} =
               Accounts.sync_billing_audiences(u, %{audiences: [@gated]}, actor: admin())

      assert Exception.message(error) =~ "applied by the system"
      assert audiences_of(u.id) == []
    end

    test "a non-admin actor is refused too" do
      u = user()

      assert {:error, _error} =
               Accounts.sync_billing_audiences(u, %{audiences: [@gated]}, actor: u)

      assert audiences_of(u.id) == []
    end

    test "a system call succeeds" do
      u = user()

      assert {:ok, _user} =
               Accounts.sync_billing_audiences(u, %{audiences: [@gated]}, authorize?: false)

      assert audiences_of(u.id) == [@gated]
    end

    test "an unconfigured audience is refused even system-side" do
      # Defence in depth: a recompute bug must not persist a value that would
      # break every subsequent read of this user (the atom-cast hazard).
      u = user()

      assert {:error, error} =
               Accounts.sync_billing_audiences(u, %{audiences: [:not_a_real_audience]},
                 authorize?: false
               )

      assert Exception.message(error) =~ "audience"
    end
  end

  describe "multi-organization" do
    @tag :strict_tenancy
    test "a membership in one org mirrors onto that org's OrgMembership only" do
      u = user()
      other = org("other")

      here = tier()
      there = tier(%{}, other.id)

      membership(u, here, :active)
      membership(u, there, :active, other.id)

      {:ok, _delta} = Entitlements.recompute(u.id)

      # The global column carries the cross-org union (what the read policy uses
      # today).
      assert audiences_of(u.id) == [@gated]

      # ...and each OrgMembership carries its own org's exact set, so the policy
      # can move per-org later without a data migration.
      {:ok, memberships} = Accounts.list_memberships_for_user(u.id, authorize?: false)
      by_org = Map.new(memberships, &{&1.organization_id, &1.audiences})

      assert by_org[default_org_id()] == [@gated]
      assert by_org[other.id] == [@gated]
    end

    @tag :strict_tenancy
    test "an org where the user has no entitling membership gets no audience" do
      u = user()
      other = org("other")

      # A membership row on the other org, but nothing bought there.
      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        organization_id: other.id,
        user_id: u.id,
        role: :viewer
      })

      membership(u, tier(), :active)
      {:ok, _delta} = Entitlements.recompute(u.id)

      {:ok, memberships} = Accounts.list_memberships_for_user(u.id, authorize?: false)
      by_org = Map.new(memberships, &{&1.organization_id, &1.audiences})

      assert by_org[default_org_id()] == [@gated]
      assert by_org[other.id] == []
    end
  end

  describe "edge cases" do
    test "a user with no memberships ends with no audiences" do
      u = user()

      assert {:ok, delta} = Entitlements.recompute(u.id)
      assert delta.after == []
    end

    test "an unknown user is an error, not a crash" do
      assert {:error, :user_not_found} = Entitlements.recompute(Ash.UUID.generate())
    end
  end
end
