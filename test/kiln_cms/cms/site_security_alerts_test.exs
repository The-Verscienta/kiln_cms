defmodule KilnCMS.CMS.SiteSecurityAlertsTest do
  @moduledoc """
  `KilnCMS.CMS.SiteSecurityAlerts` (#2245): a site's alert settings are its
  admins' to read and write, nobody else's; the alert path reads them as the
  `:security_alerts` system actor and cannot write them; and only kinds a write
  adds are checked against the kinds this release knows.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "ssa-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp member(org, role) do
    user = user(:viewer)

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org.id,
      user_id: user.id,
      role: role
    })

    user
  end

  setup do
    org = org("ssa")
    %{org: org, admin: member(org, :admin)}
  end

  test "a site admin saves and reads the row; it starts with failed sign-ins off", ctx do
    assert {:ok, row} = CMS.save_site_security_alerts(%{}, actor: ctx.admin, tenant: ctx.org.id)
    assert row.disabled_kinds == ["failed_sign_ins"]
    assert row.notify_admins == true
    assert row.include_full_ip == false

    assert {:ok, row} =
             CMS.save_site_security_alerts(%{disabled_kinds: [], include_full_ip: true},
               actor: ctx.admin,
               tenant: ctx.org.id
             )

    assert row.disabled_kinds == []
    assert {:ok, [read]} = CMS.list_site_security_alerts(actor: ctx.admin, tenant: ctx.org.id)
    assert read.id == row.id
    assert read.include_full_ip == true
  end

  test "editors, viewers, the anonymous and another site's admin are refused", ctx do
    CMS.save_site_security_alerts!(%{}, actor: ctx.admin, tenant: ctx.org.id)
    other_admin = member(org("ssa-other"), :admin)

    for actor <- [member(ctx.org, :editor), member(ctx.org, :viewer), nil, other_admin] do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_security_alerts(%{notify_admins: false},
                 actor: actor,
                 tenant: ctx.org.id
               )

      assert {:ok, []} = CMS.list_site_security_alerts(actor: actor, tenant: ctx.org.id)
    end
  end

  test "the alert path reads the row but cannot write it", ctx do
    CMS.save_site_security_alerts!(%{}, actor: ctx.admin, tenant: ctx.org.id)
    system = KilnCMS.OrgSettings.system(:security_alerts)

    assert {:ok, [_row]} =
             CMS.list_site_security_alerts(
               actor: system,
               tenant: ctx.org.id,
               authorize_with: :error
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             CMS.save_site_security_alerts(%{notify_admins: false},
               actor: system,
               tenant: ctx.org.id
             )
  end

  test "a kind this release does not know is refused", ctx do
    assert {:error, %Ash.Error.Invalid{} = error} =
             CMS.save_site_security_alerts(%{disabled_kinds: ["lockout", "made_up"]},
               actor: ctx.admin,
               tenant: ctx.org.id
             )

    assert Exception.message(error) =~ "made_up"
  end

  test "a kind already stored (a newer release's, after a rollback) does not block a save", ctx do
    row = CMS.save_site_security_alerts!(%{}, actor: ctx.admin, tenant: ctx.org.id)

    # What a newer release could have left behind.
    Ash.Seed.update!(row, %{disabled_kinds: ["failed_sign_ins", "ip_auto_blocked"]})

    assert {:ok, saved} =
             CMS.save_site_security_alerts(
               %{disabled_kinds: ["failed_sign_ins", "ip_auto_blocked", "lockout"]},
               actor: ctx.admin,
               tenant: ctx.org.id
             )

    assert saved.disabled_kinds == ["failed_sign_ins", "ip_auto_blocked", "lockout"]

    [current] = CMS.list_site_security_alerts!(actor: ctx.admin, tenant: ctx.org.id)

    assert {:ok, _} =
             CMS.update_site_security_alerts(current, %{notify_admins: false},
               actor: ctx.admin,
               tenant: ctx.org.id
             )
  end

  test "resetting the row returns the site to the defaults", ctx do
    row =
      CMS.save_site_security_alerts!(%{disabled_kinds: []}, actor: ctx.admin, tenant: ctx.org.id)

    assert :ok = CMS.reset_site_security_alerts(row, actor: ctx.admin, tenant: ctx.org.id)

    assert KilnCMS.Security.Alerts.settings_for(ctx.org.id) == KilnCMS.Security.Alerts.defaults()
  end
end
