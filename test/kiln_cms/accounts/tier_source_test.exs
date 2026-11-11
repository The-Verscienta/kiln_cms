defmodule KilnCMS.Accounts.TierSourceTest do
  @moduledoc """
  `Scoping.tier_source/2` and `Scoping.tier_changes/2` (#2142): the pages that
  explain a tier render from these, so they must agree with `effective_tier/2`
  — the decision — on every branch, and say truthfully what a temporary tier
  becomes, and when. The `_for_membership` twins must give the same answers from
  a membership the page read itself.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.{Organization, OrgMembership, Scoping, User}

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "tier-source-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp org do
    Ash.Seed.seed!(Organization, %{
      name: "Tier Source #{System.unique_integer([:positive])}",
      slug: "tier-source-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp member(user, org_id, role, attrs \\ %{}) do
    Ash.Seed.seed!(
      OrgMembership,
      Map.merge(%{user_id: user.id, organization_id: org_id, role: role}, attrs)
    )
  end

  defp grant(role, hours),
    do: %{
      granted_role: role,
      granted_role_expires_at: DateTime.add(DateTime.utc_now(), hours, :hour)
    }

  # Each case: the actor, the org asked about, the expected `{tier, source}`, and
  # the expected changes ahead as `{hours from now, tier}`.
  defp cases do
    default = Accounts.default_org_id()
    site = org()
    elsewhere = org()

    platform = user(:admin)

    granted_admin_member = user(:viewer, grant(:admin, 5))
    member(granted_admin_member, site.id, :editor)

    granted_admin_legacy = user(:viewer, grant(:admin, 5))

    granted_admin_foreign = user(:viewer, grant(:admin, 5))
    member(granted_admin_foreign, elsewhere.id, :editor)

    standing_member = user(:viewer)
    member(standing_member, site.id, :editor)

    granted_member = user(:viewer)
    member(granted_member, site.id, :viewer, grant(:editor, 5))

    expired_member = user(:viewer)
    member(expired_member, site.id, :viewer, grant(:admin, -1))

    # A user grant below admin does not govern a member's site tier.
    user_granted_member = user(:viewer, grant(:editor, 5))
    member(user_granted_member, site.id, :viewer)

    legacy = user(:editor)
    granted_legacy = user(:viewer, grant(:editor, 5))

    foreign = user(:editor)
    member(foreign, elsewhere.id, :editor)

    # A temporary platform admin whose live membership grant expires first: by
    # the time the platform grant ends, the membership is back to viewer.
    outlasted_member_grant = user(:viewer, grant(:admin, 5))
    member(outlasted_member_grant, site.id, :viewer, grant(:editor, 2))

    # ...and one whose membership grant outlasts it: two steps down.
    outlasting_member_grant = user(:viewer, grant(:admin, 5))
    member(outlasting_member_grant, site.id, :viewer, grant(:editor, 9))

    # A temporary platform admin who is a standing admin here anyway.
    admin_anyway = user(:viewer, grant(:admin, 5))
    member(admin_anyway, site.id, :admin)

    # A grant equal to the standing tier (the write refuses it; seeded data may
    # hold one): nothing changes when it ends.
    redundant_grant = user(:viewer)
    member(redundant_grant, site.id, :admin, grant(:admin, 5))

    [
      {"standing platform admin", platform, site.id, {:admin, :platform}, []},
      {"platform admin by grant, member here", granted_admin_member, site.id, {:admin, :platform},
       [{5, :editor}]},
      {"platform admin by grant, legacy on the default org", granted_admin_legacy, default,
       {:admin, :platform}, [{5, :viewer}]},
      {"platform admin by grant, member elsewhere only", granted_admin_foreign, site.id,
       {:admin, :platform}, [{5, :none}]},
      {"standing member", standing_member, site.id, {:editor, :member}, []},
      {"member with a live grant", granted_member, site.id, {:editor, :member}, [{5, :viewer}]},
      {"member with an expired grant", expired_member, site.id, {:viewer, :member}, []},
      {"member whose user grant is below admin", user_granted_member, site.id, {:viewer, :member},
       []},
      {"legacy on the default org", legacy, default, {:editor, :legacy}, []},
      {"legacy with a live grant", granted_legacy, default, {:editor, :legacy}, [{5, :viewer}]},
      {"legacy off the default org", legacy, site.id, {:none, :none}, []},
      {"foreign org", foreign, site.id, {:none, :none}, []},
      {"platform grant outlasting a membership grant", outlasted_member_grant, site.id,
       {:admin, :platform}, [{5, :viewer}]},
      {"membership grant outlasting a platform grant", outlasting_member_grant, site.id,
       {:admin, :platform}, [{5, :editor}, {9, :viewer}]},
      {"temporary platform admin, standing admin here", admin_anyway, site.id,
       {:admin, :platform}, []},
      {"a grant equal to the standing tier", redundant_grant, site.id, {:admin, :member}, []},
      {"a bare system actor", %{role: :admin}, site.id, {:admin, :platform}, []},
      {"no actor", nil, site.id, {:none, :none}, []}
    ]
  end

  # The hours a change is due in, rounded — the seeds are whole hours from now.
  defp hours_from_now(at), do: round(DateTime.diff(at, DateTime.utc_now(), :second) / 3600)

  defp membership_on(%{id: user_id}, org_id) when is_binary(user_id) do
    Accounts.get_org_membership!(user_id, org_id, authorize?: false, not_found_error?: false)
  end

  defp membership_on(_actor, _org_id), do: nil

  defp summary({tier, source, record}), do: {tier, source, record && Map.get(record, :id)}

  test "tier_source/2 agrees with effective_tier/2 on every branch" do
    for {name, actor, org_id, {tier, source}, _after} <- cases() do
      {resolved_tier, resolved_source, record} = Scoping.tier_source(actor, org_id)

      assert Scoping.effective_tier(actor, org_id) == resolved_tier, name
      assert {resolved_tier, resolved_source} == {tier, source}, name
      assert is_nil(record) == (source == :none), name
    end
  end

  test "tier_changes/2 names each change ahead, and when" do
    for {name, actor, org_id, _tier, expected} <- cases() do
      changes = Scoping.tier_changes(actor, org_id)
      assert Enum.map(changes, fn {at, tier} -> {hours_from_now(at), tier} end) == expected, name
    end
  end

  test "the _for_membership twins answer as the memoized lookups do" do
    for {name, actor, org_id, _tier, _changes} <- cases(), is_map(actor) do
      membership = membership_on(actor, org_id)

      # The record compares by id: the policy lookup loads `custom_role` on it.
      assert summary(Scoping.tier_source_for_membership(actor, org_id, membership)) ==
               summary(Scoping.tier_source(actor, org_id)),
             name

      assert Scoping.tier_changes_for_membership(actor, org_id, membership) ==
               Scoping.tier_changes(actor, org_id),
             name
    end
  end

  test "the governing record is the membership on the member branch, the user otherwise" do
    site = org()
    subject = user(:viewer)
    membership = member(subject, site.id, :viewer, grant(:editor, 5))

    assert {:editor, :member, %OrgMembership{id: id}} = Scoping.tier_source(subject, site.id)
    assert id == membership.id

    legacy = user(:editor)
    assert {:editor, :legacy, %User{id: legacy_id}} = Scoping.tier_source(legacy, nil)
    assert legacy_id == legacy.id
  end
end
