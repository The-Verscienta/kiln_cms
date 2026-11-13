defmodule KilnCMS.Accounts.SecondFactorEvictionTest do
  @moduledoc """
  A save of a site's two-step sign-in policy drops the open connections of
  every account it holds at once (#2247, `KilnCMS.Accounts.SecondFactorEviction`):
  each one's sockets hear `"disconnect"` on `SessionEviction.topic/1`. Nobody
  in a grace period, holding a factor, or outside the covered tiers is
  touched, and a write that is refused evicts nobody.

  Under test the eviction runs inline (`:async_analytics` is off), so the
  broadcasts have all been sent when the save returns. Each test uses a site
  of its own: the policy is cached per site on the whole node.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.SecondFactorFixtures

  alias KilnCMS.Accounts.SecondFactorEviction
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.TwoFactorRequirement
  alias KilnCMS.CMS
  alias KilnCMS.TwoFactorFixtures

  @moduletag :capture_log

  setup do
    site = org("sfev")
    {admin, _secret} = TwoFactorFixtures.enabled_user(role: :viewer)
    %{site: site, admin: member!(admin, site, :admin)}
  end

  defp save(attrs, admin, site) do
    CMS.save_site_second_factor_policy(attrs,
      actor: admin,
      tenant: site.id,
      context: %{second_factor_verified_at: DateTime.utc_now()}
    )
  end

  defp listen(user), do: KilnCMSWeb.Endpoint.subscribe(SessionEviction.topic(user.id))

  defp assert_evicted(user) do
    topic = SessionEviction.topic(user.id)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end

  defp refute_evicted(user) do
    topic = SessionEviction.topic(user.id)
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 50
  end

  test "a policy with no grace evicts everyone it covers who has no factor", %{
    site: site,
    admin: admin
  } do
    held = editor(site)
    enrolled = site |> editor() |> with_app()
    reader = viewer(site)
    Enum.each([admin, held, enrolled, reader], &listen/1)

    assert {:ok, _row} = save(%{required_for: :editors, grace_days: 0}, admin, site)

    assert_evicted(held)
    refute_evicted(enrolled)
    refute_evicted(reader)
    refute_evicted(admin)
  end

  test "a policy with a grace period evicts nobody", %{site: site, admin: admin} do
    in_grace = editor(site)
    listen(in_grace)

    assert {:ok, _row} = save(%{required_for: :editors, grace_days: 14}, admin, site)

    refute_evicted(in_grace)
  end

  test "shortening a long-standing grace evicts whoever it now leaves overdue", %{
    site: site,
    admin: admin
  } do
    # Covered since long ago, with a grace that has not run out yet.
    policy_row!(site, :editors,
      grace_days: 90,
      since: DateTime.add(DateTime.utc_now(), -30, :day)
    )

    overdue = editor(site)
    listen(overdue)

    assert {:ok, _row} = save(%{required_for: :editors, grace_days: 7}, admin, site)

    assert_evicted(overdue)
  end

  test "a refused save evicts nobody", %{site: site} do
    {unverified, _secret} = TwoFactorFixtures.enabled_user(role: :viewer)
    unverified = member!(unverified, site, :admin)
    held = editor(site)
    listen(held)

    assert {:error, _} =
             CMS.save_site_second_factor_policy(%{required_for: :editors, grace_days: 0},
               actor: unverified,
               tenant: site.id
             )

    refute_evicted(held)
  end

  test "turning it off evicts nobody", %{site: site, admin: admin} do
    policy_row!(site, :editors)
    held = editor(site)
    listen(held)

    assert {:ok, _row} = save(%{required_for: :off, grace_days: 0}, admin, site)

    refute_evicted(held)
  end

  test "evicts the same accounts the roster counts as overdue", %{site: site} do
    row = policy_row!(site, :everyone)
    held = [editor(site), viewer(site)]
    _enrolled = site |> viewer() |> with_app()

    policy = TwoFactorRequirement.from_row(row)
    evicted = SecondFactorEviction.evict_overdue(site.id, policy)

    assert Enum.sort(evicted) == held |> Enum.map(& &1.id) |> Enum.sort()

    overdue =
      site.id |> TwoFactorRequirement.roster(policy) |> Map.values() |> Enum.map(& &1.overdue)

    assert Enum.sum(overdue) == length(evicted)
  end
end
