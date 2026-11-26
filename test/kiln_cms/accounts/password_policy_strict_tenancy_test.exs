defmodule KilnCMS.Accounts.PasswordPolicyStrictTenancyTest do
  @moduledoc """
  The strictest-policy rule across a target's admin orgs (#2408) under strict
  tenancy (`global?: false`).

  In the default (fail-open) test build a tenant-less read of
  `SitePasswordPolicy` returns every org's rows, so the cross-org code would
  pass there even through the wrong, tenanted action. Here it cannot: these
  assert the escalation positively, on the build where only the
  `multitenancy :bypass` actions can see another org's row.

  Runs ONLY on the strict CI leg (`KILN_STRICT_TEST=1`, see test_helper.exs).
  `async: false`: the check's switch and operator default are application env.
  """
  use KilnCMS.DataCase, async: false

  @moduletag :strict_tenancy

  import KilnCMS.BreachedPasswordFixtures, only: [default_policy!: 1]
  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.BreachedPassword
  alias KilnCMS.Accounts.PasswordPolicy
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.OrgSettings

  setup do
    original = Application.get_env(:kiln_cms, BreachedPassword, [])
    Application.put_env(:kiln_cms, BreachedPassword, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:kiln_cms, BreachedPassword, original) end)

    %{a: org("strict-pwpol-a"), b: org("strict-pwpol-b")}
  end

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "strict-pwpol-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp save!(org, policy) do
    CMS.save_site_password_policy!(%{breached_password_policy: policy},
      actor: user(:admin),
      tenant: org
    )
  end

  defp member!(org, user, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org.id,
      user_id: user.id,
      role: role
    })
  end

  test "the strict build is strict for the password policy rows" do
    refute Ash.Resource.Info.multitenancy_global?(KilnCMS.CMS.SitePasswordPolicy)
  end

  test "an admin of a :block org is :block on a :warn or :off org", %{a: a, b: b} do
    save!(a, :block)
    member = user(:viewer)
    member!(a, member, :admin)
    member!(b, member, :viewer)

    save!(b, :warn)
    assert PasswordPolicy.resolve_for(member, b.id, :viewer) == :block

    save!(b, :off)
    assert PasswordPolicy.resolve_for(member, b.id, :viewer) == :block
    assert PasswordPolicy.read_for(member, b.id, :viewer) == {:ok, :block}
  end

  test "a platform admin is :block on an :off org while another org blocks", %{a: a, b: b} do
    save!(a, :block)
    save!(b, :off)
    assert PasswordPolicy.resolve_for(user(:admin), b.id, :admin) == :block
  end

  test "a platform admin's operator default is counted across orgs", %{b: b} do
    save!(b, :off)
    default_policy!(:block)
    assert PasswordPolicy.resolve_for(user(:admin), b.id, :admin) == :block
  end

  test "the cross-org reads stay the system actor's alone", %{a: a} do
    save!(a, :block)
    admin_of_a = user(:viewer)
    member!(a, admin_of_a, :admin)

    assert {:ok, [%{breached_password_policy: :block}]} =
             CMS.list_site_password_policies_for_orgs([a.id],
               actor: OrgSettings.system(:accounts),
               authorize_with: :error
             )

    for actor <- [admin_of_a, user(:admin)] do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.list_site_password_policies_for_orgs([a.id],
                 actor: actor,
                 authorize_with: :error
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.list_all_site_password_policies(actor: actor, authorize_with: :error)
    end
  end

  describe "at sign-in (#2407)" do
    defp save_sign_in!(org, policy, check_on_sign_in) do
      CMS.save_site_password_policy!(
        %{breached_password_policy: policy, check_on_sign_in: check_on_sign_in},
        actor: user(:admin),
        tenant: org
      )
    end

    test "an admin of a site checking at sign-in under :block is checked under :block",
         %{a: a, b: b} do
      save_sign_in!(a, :block, true)
      save_sign_in!(b, :warn, true)
      admin_of_a = user(:viewer)
      member!(a, admin_of_a, :admin)
      member!(b, admin_of_a, :viewer)

      assert PasswordPolicy.sign_in(admin_of_a) == {:check, :block}
      assert {:check, :block, deciding} = PasswordPolicy.sign_in_decision(admin_of_a)
      assert deciding.() == [a.id]
    end

    test "only the switched-on admin orgs count, read across tenants", %{a: a, b: b} do
      save_sign_in!(a, :warn, true)
      save_sign_in!(b, :block, false)
      admin = user(:viewer)
      member!(a, admin, :admin)
      member!(b, admin, :admin)

      assert PasswordPolicy.sign_in(admin) == {:check, :warn}
    end

    test "a platform admin is checked by any org with the switch on", %{a: a, b: b} do
      save_sign_in!(a, :warn, false)
      save_sign_in!(b, :block, true)
      admin = user(:admin)

      assert PasswordPolicy.sign_in(admin) == {:check, :block}
      assert {:check, :block, deciding} = PasswordPolicy.sign_in_decision(admin)
      assert deciding.() == [b.id]
    end
  end
end
