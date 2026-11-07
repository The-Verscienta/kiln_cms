defmodule KilnCMS.Accounts.PasswordPolicyTest do
  @moduledoc """
  The breached-password policy ladder (#2240): site row, operator default,
  `:warn`; `:block` only for an admin target; every failure to read the row
  fails open to `:warn`.

  `async: false`: the operator default and the kill switch are application env.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog
  import KilnCMS.BreachedPasswordFixtures, only: [default_policy!: 1]
  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.BreachedPassword
  alias KilnCMS.Accounts.PasswordPolicy
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.OrgSettings
  alias KilnCMS.SystemActor

  setup do
    original = Application.get_env(:kiln_cms, BreachedPassword, [])
    # The check is off in the suite; the resolver answers `:off` while it is.
    Application.put_env(:kiln_cms, BreachedPassword, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:kiln_cms, BreachedPassword, original) end)

    %{org: org("pwpol"), other: org("pwpol-other")}
  end

  defp user(role, extra \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "pwpol-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        extra
      )
    )
  end

  defp save!(org, policy, actor \\ nil) do
    CMS.save_site_password_policy!(%{breached_password_policy: policy},
      actor: actor || user(:admin),
      tenant: org
    )
  end

  describe "the ladder" do
    test "no row and no operator setting is :warn", %{org: org} do
      assert PasswordPolicy.resolve(org.id, :viewer) == :warn
      assert PasswordPolicy.resolve(org.id, :admin) == :warn
    end

    test "the operator default applies when the site has no row", %{org: org} do
      default_policy!(:off)
      assert PasswordPolicy.resolve(org.id, :admin) == :off

      default_policy!(:block)
      assert PasswordPolicy.resolve(org.id, :admin) == :block
    end

    test "the site's row beats the operator default", %{org: org} do
      default_policy!(:block)
      save!(org, :off)
      assert PasswordPolicy.resolve(org.id, :admin) == :off

      default_policy!(:off)
      save!(org, :block)
      assert PasswordPolicy.resolve(org.id, :admin) == :block
    end

    test "an org struct, an id and nil are all orgs", %{org: org} do
      save!(org, :block)
      assert PasswordPolicy.resolve(org, :admin) == :block
      assert PasswordPolicy.resolve(org.id, :admin) == :block
      assert PasswordPolicy.resolve(nil, :admin) == :warn
    end

    test "the deployment switch overrides any row", %{org: org} do
      save!(org, :block)
      original = Application.get_env(:kiln_cms, BreachedPassword)
      Application.put_env(:kiln_cms, BreachedPassword, Keyword.put(original, :enabled, false))

      assert PasswordPolicy.resolve(org.id, :admin) == :off
    end
  end

  describe "the target's tier" do
    for {policy, tier, expected} <- [
          {:off, :admin, :off},
          {:off, :editor, :off},
          {:off, :viewer, :off},
          {:warn, :admin, :warn},
          {:warn, :editor, :warn},
          {:warn, :viewer, :warn},
          {:block, :admin, :block},
          {:block, :editor, :warn},
          {:block, :viewer, :warn},
          {:block, :none, :warn}
        ] do
      test "#{policy} for a #{tier} target is #{expected}", %{org: org} do
        save!(org, unquote(policy))
        assert PasswordPolicy.resolve(org.id, unquote(tier)) == unquote(expected)
      end
    end

    test "an account that is a viewer globally but an admin of the org by membership is :block",
         %{org: org} do
      save!(org, :block)
      member = user(:viewer)

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: org.id,
        user_id: member.id,
        role: :admin
      })

      assert PasswordPolicy.target_tier(member, org.id) == :admin
      assert PasswordPolicy.resolve(org.id, PasswordPolicy.target_tier(member, org.id)) == :block
    end

    test "the stricter of the standing role and the org tier wins", %{org: org} do
      admin = user(:admin)
      assert PasswordPolicy.target_tier(admin, org.id) == :admin

      editor = user(:editor)

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: org.id,
        user_id: editor.id,
        role: :viewer
      })

      # Editor globally, viewer here: the global role is the stricter.
      assert PasswordPolicy.target_tier(editor, org.id) == :editor
    end

    test "a live temporary admin grant counts" do
      user =
        user(:viewer, %{
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        })

      assert PasswordPolicy.target_tier(user, nil) == :admin
    end

    test "an account that does not exist yet is a viewer" do
      assert PasswordPolicy.target_tier(nil, nil) == :viewer
    end
  end

  describe "failing open" do
    test "a refused settings read is :warn, not :off and not :block", %{org: org} do
      save!(org, :block)

      log =
        capture_log(fn ->
          assert OrgSettings.with_actor(nil, fn -> PasswordPolicy.resolve(org.id, :admin) end) ==
                   :warn
        end)

      assert log =~ "breached password policy lookup failed"

      # Nothing was remembered: the next read sees the row again.
      assert PasswordPolicy.resolve(org.id, :admin) == :block
    end

    test "a refused read does not read as 'no row' (the operator default)", %{org: org} do
      default_policy!(:off)
      save!(org, :block)

      capture_log(fn ->
        assert OrgSettings.with_actor(nil, fn -> PasswordPolicy.resolve(org.id, :admin) end) ==
                 :warn
      end)
    end
  end

  describe "SitePasswordPolicy" do
    test "saving is an admin act: an editor and a viewer are refused", %{org: org} do
      for role <- [:editor, :viewer] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.save_site_password_policy(%{breached_password_policy: :off},
                   actor: user(role),
                   tenant: org
                 )
      end

      assert [] = CMS.list_site_password_policy!(actor: user(:admin), tenant: org)
    end

    test "the value is constrained to off, warn and block", %{org: org} do
      assert {:error, %Ash.Error.Invalid{}} =
               CMS.save_site_password_policy(%{breached_password_policy: :strict},
                 actor: user(:admin),
                 tenant: org
               )
    end

    test "a row is one per org, and one org's does not reach another's", %{org: a, other: b} do
      save!(a, :block)
      save!(b, :off)
      save!(a, :off)

      assert [%{breached_password_policy: :off}] =
               CMS.list_site_password_policy!(actor: user(:admin), tenant: a)

      assert PasswordPolicy.resolve(a.id, :admin) == :off
      assert PasswordPolicy.resolve(b.id, :admin) == :off

      save!(a, :block)
      assert PasswordPolicy.resolve(a.id, :admin) == :block
      assert PasswordPolicy.resolve(b.id, :admin) == :off
    end

    test "the system actor reads the row but cannot write it; no actor reads nothing",
         %{org: org} do
      row = save!(org, :block)
      system = OrgSettings.system(:accounts)
      assert %SystemActor{subsystem: :accounts} = system

      assert [%{id: id}] =
               CMS.list_site_password_policy!(actor: system, tenant: org, authorize_with: :error)

      assert id == row.id

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_password_policy(%{breached_password_policy: :off},
                 actor: system,
                 tenant: org
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.reset_site_password_policy(row, actor: system, tenant: org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.list_site_password_policy(tenant: org, authorize_with: :error)
    end

    test "a different subsystem's actor cannot read it", %{org: org} do
      save!(org, :block)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.list_site_password_policy(
                 actor: SystemActor.new(:feeds),
                 tenant: org,
                 authorize_with: :error
               )
    end

    test "an admin of another org cannot read this org's row", %{org: a, other: b} do
      save!(a, :block)
      outsider = user(:viewer)

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: b.id,
        user_id: outsider.id,
        role: :admin
      })

      assert {:error, _} =
               CMS.list_site_password_policy(actor: outsider, tenant: a, authorize_with: :error)
    end
  end
end
