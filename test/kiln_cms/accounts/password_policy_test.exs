defmodule KilnCMS.Accounts.PasswordPolicyTest do
  @moduledoc """
  The breached-password policy ladder (#2240): site row, operator default,
  `:warn`; `:block` only for an admin target; every failure to read the row
  fails open to `:warn`. And the strictest policy across every org the target
  administers (#2408), read in a bounded number of queries through the
  system-only cross-org actions.

  `async: false`: the operator default and the kill switch are application env.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog
  import KilnCMS.BreachedPasswordFixtures, only: [default_policy!: 1]
  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.BreachedPassword
  alias KilnCMS.Accounts.PasswordPolicy
  alias KilnCMS.Accounts.Scoping
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

  defp membership!(org, user, role, extra \\ %{}) do
    Ash.Seed.seed!(
      Accounts.OrgMembership,
      Map.merge(%{organization_id: org.id, user_id: user.id, role: role}, extra)
    )
  end

  # A viewer globally who is an admin of `org` by membership.
  defp member_admin_of(org, extra \\ %{}) do
    member = user(:viewer)
    membership!(org, member, :admin, extra)
    member
  end

  # The tier `CheckBreachedPassword` would pass for `user` setting a password on `org`.
  defp resolve_on(user, org),
    do: PasswordPolicy.resolve_for(user, org.id, PasswordPolicy.target_tier(user, org.id))

  describe "Scoping.admin_org_ids/1" do
    test "a platform admin administers every org" do
      assert Scoping.admin_org_ids(user(:admin)) == :all
    end

    test "a member admin administers exactly the orgs of their active admin memberships",
         %{org: a, other: b} do
      member = member_admin_of(a)
      membership!(b, member, :editor)
      assert Scoping.admin_org_ids(member) == [a.id]
    end

    test "a pending or rejected admin membership and an expired grant do not count; a live grant does",
         %{org: a, other: b} do
      pending = member_admin_of(a, %{status: :pending})
      rejected = member_admin_of(b, %{status: :rejected})
      assert Scoping.admin_org_ids(pending) == []
      assert Scoping.admin_org_ids(rejected) == []

      expired = user(:viewer)
      past = DateTime.add(DateTime.utc_now(), -3600)
      membership!(a, expired, :viewer, %{granted_role: :admin, granted_role_expires_at: past})
      assert Scoping.admin_org_ids(expired) == []

      live = user(:viewer)
      future = DateTime.add(DateTime.utc_now(), 3600)
      membership!(a, live, :viewer, %{granted_role: :admin, granted_role_expires_at: future})
      assert Scoping.admin_org_ids(live) == [a.id]
    end

    test "an erased account, no account and a non-admin administer nothing", %{org: a} do
      assert Scoping.admin_org_ids(user(:admin, %{anonymized_at: DateTime.utc_now()})) == []
      assert Scoping.admin_org_ids(member_admin_of(a, %{})) == [a.id]

      erased_member = member_admin_of(a)
      erased_member = Ash.Seed.update!(erased_member, %{anonymized_at: DateTime.utc_now()})
      assert Scoping.admin_org_ids(erased_member) == []

      assert Scoping.admin_org_ids(nil) == []
      assert Scoping.admin_org_ids(user(:editor)) == []
    end
  end

  describe "the strictest policy across the target's admin orgs (#2408)" do
    test "an admin of a block org is blocked on an org where they are a viewer, even one that is off",
         %{org: a, other: b} do
      save!(a, :block)
      member = member_admin_of(a)
      membership!(b, member, :viewer)

      save!(b, :warn)
      assert resolve_on(member, b) == :block

      save!(b, :off)
      assert resolve_on(member, b) == :block
      assert PasswordPolicy.read_for(member, b.id, :viewer) == {:ok, :block}
    end

    test "an admin of a warn org is warned on an org that is off", %{org: a, other: b} do
      save!(a, :warn)
      save!(b, :off)
      assert resolve_on(member_admin_of(a), b) == :warn
    end

    test "an admin org with no row brings in the operator default", %{org: a, other: b} do
      default_policy!(:block)
      save!(b, :off)
      assert resolve_on(member_admin_of(a), b) == :block
    end

    test "an editor of a block org is not escalated: :block applies to admins only",
         %{org: a, other: b} do
      save!(a, :block)
      save!(b, :warn)
      editor = user(:viewer)
      membership!(a, editor, :editor)
      assert resolve_on(editor, b) == :warn
    end

    test "a pending or rejected admin membership does not escalate", %{org: a, other: b} do
      save!(a, :block)
      save!(b, :off)

      assert resolve_on(member_admin_of(a, %{status: :pending}), b) == :off
      assert resolve_on(member_admin_of(a, %{status: :rejected}), b) == :off
    end

    test "an expired temporary admin grant does not escalate; a live one does",
         %{org: a, other: b} do
      save!(a, :block)
      save!(b, :off)

      expired = user(:viewer)
      past = DateTime.add(DateTime.utc_now(), -3600)
      membership!(a, expired, :viewer, %{granted_role: :admin, granted_role_expires_at: past})
      assert resolve_on(expired, b) == :off

      live = user(:viewer)
      future = DateTime.add(DateTime.utc_now(), 3600)
      membership!(a, live, :viewer, %{granted_role: :admin, granted_role_expires_at: future})
      assert resolve_on(live, b) == :block
    end

    test "an erased account is not escalated", %{org: a, other: b} do
      save!(a, :block)
      save!(b, :off)
      erased = a |> member_admin_of() |> Ash.Seed.update!(%{anonymized_at: DateTime.utc_now()})
      assert PasswordPolicy.resolve_for(erased, b.id, :viewer) == :off
    end

    test "a platform admin gets the strictest of every org's row", %{org: a, other: b} do
      save!(a, :block)
      save!(b, :off)
      assert resolve_on(user(:admin), b) == :block
    end

    test "for a platform admin the operator default takes part while some org has no row",
         %{other: b} do
      save!(b, :off)
      default_policy!(:block)
      # The default org and `org` have no row.
      assert resolve_on(user(:admin), b) == :block

      default_policy!(:warn)
      assert resolve_on(user(:admin), b) == :warn
    end

    test "for a platform admin the operator default is out once every org has a row" do
      admin = user(:admin)

      for org <- Accounts.list_organizations!(authorize?: false) do
        save!(org, :off, admin)
      end

      default_policy!(:block)
      assert PasswordPolicy.resolve_for(admin, nil, :admin) == :off
    end

    test "no target (an account not created yet) is the request org's answer alone",
         %{org: a, other: b} do
      save!(a, :block)
      save!(b, :off)
      assert PasswordPolicy.resolve_for(nil, b.id, :viewer) == :off
      assert PasswordPolicy.resolve(b.id, :viewer) == :off
      assert PasswordPolicy.read(b.id, :viewer) == {:ok, :off}
    end

    test "the deployment switch overrides every admin org's row", %{org: a, other: b} do
      save!(a, :block)
      member = member_admin_of(a)
      original = Application.get_env(:kiln_cms, BreachedPassword)
      Application.put_env(:kiln_cms, BreachedPassword, Keyword.put(original, :enabled, false))

      assert resolve_on(member, b) == :off
      assert PasswordPolicy.read_for(member, b.id, :viewer) == {:ok, :off}
    end
  end

  describe "the cross-org read fails open (#2408)" do
    test "a refused read is :warn, and the log names nobody", %{org: a, other: b} do
      save!(a, :block)
      save!(b, :off)
      member = member_admin_of(a)

      log =
        capture_log(fn ->
          assert OrgSettings.with_actor(nil, fn -> resolve_on(member, b) end) == :warn
        end)

      assert log =~ "other sites could not be read; treating as warn"

      # The request org's own refused read logs its query, as it always has;
      # nothing anywhere names the account, and the cross-org line names no org.
      for secret <- [member.id, to_string(member.email)], do: refute(log =~ secret)

      line =
        log
        |> String.split("\n")
        |> Enum.find(&(&1 =~ "other sites could not be read"))

      for secret <- [a.id, b.id], do: refute(line =~ secret)

      # The request org's own row was readable here: only the cross-org part failed.
      assert PasswordPolicy.read_for(member, b.id, :viewer) == {:ok, :block}
    end

    test "a raise while reading the target's admin orgs is :warn, not a crash", %{org: b} do
      save!(b, :off)
      # An id no membership query can take: the read raises.
      broken = %{user(:viewer) | id: "not-a-uuid"}

      log =
        capture_log(fn ->
          assert PasswordPolicy.resolve_for(broken, b.id, :viewer) == :warn
        end)

      assert log =~ "other sites could not be read; treating as warn"
    end
  end

  describe "the cross-org read is bounded (#2408)" do
    # Queries this process runs while `fun` does: the cross-org part is the
    # difference from the same call with no target.
    defp queries(fun) do
      test = self()
      handler = "pwpol-queries-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:kiln_cms, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == test, do: send(test, :query)
        end,
        nil
      )

      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

      count_queries(0)
    end

    defp count_queries(n) do
      receive do
        :query -> count_queries(n + 1)
      after
        0 -> n
      end
    end

    defp extra_queries(user, org) do
      baseline = queries(fn -> PasswordPolicy.resolve_for(nil, org.id, :viewer) end)
      queries(fn -> PasswordPolicy.resolve_for(user, org.id, :viewer) end) - baseline
    end

    test "a member admin costs two queries, with one admin org or six", %{other: b} do
      save!(b, :off)
      default_policy!(:block)

      one = member_admin_of(org("pwpol-one"))

      six = user(:viewer)
      for n <- 1..6, do: membership!(org("pwpol-six-#{n}"), six, :admin)

      assert length(Scoping.admin_org_ids(six)) == 6
      assert extra_queries(one, b) <= 2
      assert extra_queries(six, b) == extra_queries(one, b)
    end

    test "a platform admin costs at most three, however many orgs", %{other: b} do
      save!(b, :off)
      default_policy!(:block)
      admin = user(:admin)
      for n <- 1..6, do: save!(org("pwpol-many-#{n}"), :off, admin)

      assert extra_queries(admin, b) <= 3
    end
  end

  describe "the cross-org actions are the breached-password check's alone (#2408)" do
    setup %{org: a, other: b} do
      save!(a, :block)
      save!(b, :off)
      :ok
    end

    defp for_orgs(org_ids, actor) do
      CMS.list_site_password_policies_for_orgs(org_ids, actor: actor, authorize_with: :error)
    end

    defp all_orgs(actor),
      do: CMS.list_all_site_password_policies(actor: actor, authorize_with: :error)

    test "the accounts system actor reads the named orgs' rows, and every org's",
         %{org: a, other: b} do
      system = OrgSettings.system(:accounts)

      assert {:ok, rows} = for_orgs([a.id], system)
      assert [{a.id, :block}] == Enum.map(rows, &{&1.org_id, &1.breached_password_policy})

      assert {:ok, rows} = all_orgs(system)
      ids = Enum.map(rows, & &1.org_id)
      assert a.id in ids and b.id in ids
    end

    test "a site admin is refused, though the macro's read policy would admit them",
         %{org: a, other: b} do
      admin_of_a = member_admin_of(a)
      assert {:error, %Ash.Error.Forbidden{}} = for_orgs([a.id], admin_of_a)
      assert {:error, %Ash.Error.Forbidden{}} = for_orgs([b.id], admin_of_a)
      assert {:error, %Ash.Error.Forbidden{}} = all_orgs(admin_of_a)
    end

    test "a platform admin, an editor, a viewer and no actor are refused", %{org: a} do
      for actor <- [user(:admin), user(:editor), user(:viewer), nil] do
        assert {:error, %Ash.Error.Forbidden{}} = for_orgs([a.id], actor)
        assert {:error, %Ash.Error.Forbidden{}} = all_orgs(actor)
      end
    end

    test "another subsystem's system actor is refused", %{org: a} do
      feeds = SystemActor.new(:feeds)
      assert {:error, %Ash.Error.Forbidden{}} = for_orgs([a.id], feeds)
      assert {:error, %Ash.Error.Forbidden{}} = all_orgs(feeds)
    end

    test "an empty list is refused, not read as every org" do
      assert {:error, %Ash.Error.Invalid{}} = for_orgs([], OrgSettings.system(:accounts))
    end

    test "the accounts system actor still cannot write a row", %{org: a} do
      [row] = CMS.list_site_password_policy!(actor: user(:admin), tenant: a)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.reset_site_password_policy(row,
                 actor: OrgSettings.system(:accounts),
                 tenant: a
               )
    end
  end
end
