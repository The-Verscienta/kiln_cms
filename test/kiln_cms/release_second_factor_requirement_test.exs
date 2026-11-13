defmodule KilnCMS.ReleaseSecondFactorRequirementTest do
  @moduledoc """
  `KilnCMS.Release.second_factor_requirement_off/1` (#2247): the operator's way
  back in when no administrator of a site can pass its two-step sign-in
  requirement. Turns it off — and only off — as the `:operator` system actor,
  records the change in the site's security log and reaches every page at
  once.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureIO
  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.TwoFactorRequirement
  alias KilnCMS.CMS
  alias KilnCMS.Release
  alias KilnCMS.Security

  setup do
    %{site: org("sfp-rel")}
  end

  defp require!(site, required_for) do
    admin =
      Ash.Seed.seed!(Accounts.User, %{
        email: "sfp-rel-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: site.id,
      user_id: admin.id,
      role: :admin
    })

    Ash.Seed.seed!(Accounts.Passkey, %{
      user_id: admin.id,
      name: "Key",
      credential_id: "cred-#{System.unique_integer([:positive])}",
      public_key: <<1>>,
      sign_count: 0
    })

    CMS.save_site_second_factor_policy!(%{required_for: required_for, grace_days: 0},
      actor: admin,
      tenant: site.id,
      context: %{second_factor_verified_at: DateTime.utc_now()}
    )
  end

  defp run(site, opts \\ [], serving? \\ true) do
    test = self()
    opts = Keyword.put(opts, :org, site.slug)

    out =
      capture_io(fn ->
        send(test, {:result, Release.run_second_factor_requirement_off(opts, serving?)})
      end)

    assert_received {:result, result}
    {result, out}
  end

  defp stored(site) do
    CMS.list_site_second_factor_policy!(
      actor: KilnCMS.SystemActor.new(:operator),
      tenant: site.id
    )
    |> hd()
  end

  defp console_events(site) do
    reader =
      Ash.Seed.seed!(Accounts.User, %{
        email: "sfp-rel-reader-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    Security.list_events!(actor: reader, tenant: site.id, page: [limit: 50])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(
      &(&1.type == :second_factor_policy_changed and &1.metadata["via"] == "console")
    )
  end

  test "turns the requirement off, reaches the pages at once and is in the log", %{site: site} do
    require!(site, :everyone)
    Phoenix.PubSub.subscribe(KilnCMS.PubSub, TwoFactorRequirement.topic(site.id))

    assert {{:ok, :off}, out} = run(site)
    assert out =~ "Turned off the two-step sign-in requirement (it was: everyone)"

    assert %{required_for: :off, grace_days: 0} = stored(site)
    assert_receive {:second_factor_policy_changed, %{required_for: :off}}
    assert TwoFactorRequirement.policy(site.id).required_for == :off

    assert [event] = console_events(site)
    assert event.actor_id == nil
    assert event.metadata["previous_required_for"] == "everyone"
    assert event.metadata["change"] == "weakened"
  end

  test "a site that requires nothing is left alone, and nothing is logged", %{site: site} do
    assert {{:ok, :off}, out} = run(site)
    assert out =~ "does not require two-step sign-in"
    assert console_events(site) == []

    require!(site, :off)
    assert {{:ok, :off}, _out} = run(site)
    assert console_events(site) == []
  end

  test "an unknown site is an error", %{site: site} do
    assert {{:error, message}, out} = run(%{site | slug: "no-such-site"})
    assert message =~ "No organization"
    assert out =~ message
  end

  test "refuses to run without the serving application (eval, not rpc)", %{site: site} do
    require!(site, :admins)

    assert {{:error, message}, _out} = run(site, [], false)
    assert message =~ "bin/kiln_cms rpc"
    assert %{required_for: :admins} = stored(site)
  end
end
