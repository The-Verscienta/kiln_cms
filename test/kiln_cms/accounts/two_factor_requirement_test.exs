defmodule KilnCMS.Accounts.TwoFactorRequirementTest do
  @moduledoc """
  `KilnCMS.Accounts.TwoFactorRequirement` (#2247): an account's status under a
  site's two-step sign-in requirement — tier × policy × factor × clock — the
  deadline rule (promotions do not restart the grace, a new member's starts
  with the membership), the passkey-only step-up, whether any site requires a
  factor, the promotion warning, the roster counts, and the cached policy's
  fail-open read.

  Most tests hand `status/3` a `Policy` and a clock, so the matrix is pure
  logic; the reads are covered where they matter. Demo mode, which needs
  `Application.put_env`, is in `TwoFactorRequirementDemoTest` below.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.TwoFactorRequirement
  alias KilnCMS.Accounts.TwoFactorRequirement.Policy
  alias KilnCMS.TwoFactorFixtures

  @moduletag :capture_log

  # The day the policy covered its tiers, and the clock the matrix reads.
  @since ~U[2026-11-01 00:00:00.000000Z]
  @long_ago ~U[2026-01-01 00:00:00.000000Z]
  @day 86_400

  defp policy(required_for, grace_days \\ 14) do
    covered = KilnCMS.CMS.SiteSecondFactorPolicy.covered_tiers(required_for)

    %Policy{
      required_for: required_for,
      grace_days: grace_days,
      since: Map.new([:admin, :editor, :viewer], &{&1, if(&1 in covered, do: @since)})
    }
  end

  defp at(days), do: DateTime.add(@since, round(days * @day), :second)

  defp user(attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.User,
      Map.merge(
        %{
          email: "tfr-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :viewer,
          inserted_at: @long_ago
        },
        attrs
      )
    )
  end

  defp totp_user do
    {user, _secret} =
      TwoFactorFixtures.enabled_user(
        role: :viewer,
        email: "tfr-totp-#{System.unique_integer([:positive])}@example.com",
        inserted_at: @long_ago
      )

    user
  end

  defp member!(user, site, role, attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.OrgMembership,
      Map.merge(
        %{organization_id: site.id, user_id: user.id, role: role, inserted_at: @long_ago},
        attrs
      )
    )

    user
  end

  defp passkey!(user) do
    Ash.Seed.seed!(Accounts.Passkey, %{
      user_id: user.id,
      name: "Key",
      credential_id: "cred-#{System.unique_integer([:positive])}",
      public_key: <<1, 2, 3>>,
      sign_count: 0
    })

    user
  end

  defp status(user, site, policy, days),
    do: TwoFactorRequirement.status(user, site.id, policy: policy, now: at(days))

  setup do
    %{site: org("tfr")}
  end

  describe "status/3" do
    test "off requires nothing of anyone", %{site: site} do
      admin = member!(user(), site, :admin)
      assert status(admin, site, policy(:off), 100) == :not_required
    end

    test "a tier the policy does not cover is not required", %{site: site} do
      editor = member!(user(), site, :editor)
      viewer = member!(user(), site, :viewer)

      assert status(editor, site, policy(:admins), 100) == :not_required
      assert status(viewer, site, policy(:editors), 100) == :not_required
      assert {:enforced, _} = status(viewer, site, policy(:everyone), 100)
    end

    test "each covered tier, by policy", %{site: site} do
      admin = member!(user(), site, :admin)
      editor = member!(user(), site, :editor)

      for required_for <- [:admins, :editors, :everyone] do
        assert {:grace, _} = status(admin, site, policy(required_for), 1)
      end

      assert {:grace, _} = status(editor, site, policy(:editors), 1)
      assert {:grace, _} = status(editor, site, policy(:everyone), 1)
    end

    test "an authenticator app is enrolled", %{site: site} do
      admin = member!(totp_user(), site, :admin)
      assert status(admin, site, policy(:admins), 100) == :enrolled
    end

    test "a passkey alone is enrolled", %{site: site} do
      admin = site |> then(&member!(user(), &1, :admin)) |> passkey!()
      assert status(admin, site, policy(:admins), 100) == :enrolled
    end

    test "grace up to the deadline, enforced from it", %{site: site} do
      admin = member!(user(), site, :admin)
      deadline = at(14)

      assert status(admin, site, policy(:admins), 0) == {:grace, deadline}

      assert TwoFactorRequirement.status(admin, site.id,
               policy: policy(:admins),
               now: DateTime.add(deadline, -1, :second)
             ) == {:grace, deadline}

      assert TwoFactorRequirement.status(admin, site.id, policy: policy(:admins), now: deadline) ==
               {:enforced, deadline}
    end

    test "a grace of 0 is enforced as soon as the tier is covered", %{site: site} do
      admin = member!(user(), site, :admin)
      assert status(admin, site, policy(:admins, 0), 0) == {:enforced, @since}
    end

    test "a promotion keeps the membership's start", %{site: site} do
      account = member!(user(), site, :viewer)
      membership = Accounts.get_org_membership!(account.id, site.id, authorize?: false)

      Ash.Seed.update!(membership, %{role: :admin})

      # Covered since 1 Nov, membership and account from January: the
      # promotion today does not restart the 14 days.
      assert status(account, site, policy(:admins), 30) == {:enforced, at(14)}
    end

    test "a new member's grace starts with the membership", %{site: site} do
      newcomer = member!(user(), site, :admin, %{inserted_at: at(5)})
      assert status(newcomer, site, policy(:admins), 10) == {:grace, at(19)}
    end

    test "a new account's grace starts with the account", %{site: site} do
      account = member!(user(%{inserted_at: at(3)}), site, :editor, %{inserted_at: at(3)})
      assert status(account, site, policy(:editors), 10) == {:grace, at(17)}
    end

    test "a platform admin is covered on every site that covers admins", %{site: site} do
      platform = user(%{role: :admin})

      assert {:grace, _} = status(platform, site, policy(:admins), 1)
      assert {:grace, _} = status(platform, org("tfr-elsewhere"), policy(:admins), 1)
    end

    test "a legacy membership-less account is held on the default site by its own role" do
      default = %{id: Accounts.default_org_id()}
      legacy = user(%{role: :editor})

      assert {:grace, _} = status(legacy, default, policy(:editors), 1)
      assert status(legacy, default, policy(:admins), 1) == :not_required
    end

    test "a temporary grant is covered while it lasts", %{site: site} do
      granted =
        member!(user(), site, :viewer, %{
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      assert {:grace, _} = status(granted, site, policy(:admins), 1)
    end

    test "an erased account is not required", %{site: site} do
      erased = member!(user(%{anonymized_at: DateTime.utc_now()}), site, :admin)
      assert status(erased, site, policy(:admins), 100) == :not_required
    end

    test "with no option, it reads the site's saved policy", %{site: site} do
      admin = member!(user(), site, :admin)

      Ash.Seed.seed!(KilnCMS.CMS.SiteSecondFactorPolicy, %{
        org_id: site.id,
        required_for: :admins,
        grace_days: 0,
        admin_required_since: @since,
        policy_changed_at: @since
      })

      KilnCMS.Cache.bust_second_factor_policy(site.id)

      assert TwoFactorRequirement.status(admin, site.id) == {:enforced, @since}
    end
  end

  describe "policy/1" do
    test "an unreadable row fails open, and the failure is not cached", %{site: site} do
      Ash.Seed.seed!(KilnCMS.CMS.SiteSecondFactorPolicy, %{
        org_id: site.id,
        required_for: :everyone,
        grace_days: 0,
        admin_required_since: @since,
        editor_required_since: @since,
        viewer_required_since: @since,
        policy_changed_at: @since
      })

      KilnCMS.Cache.bust_second_factor_policy(site.id)

      refused =
        KilnCMS.OrgSettings.with_actor(KilnCMS.SystemActor.new(:not_accounts), fn ->
          TwoFactorRequirement.policy(site.id)
        end)

      assert refused == TwoFactorRequirement.off()

      assert KilnCMS.OrgSettings.with_actor(KilnCMS.SystemActor.new(:not_accounts), fn ->
               TwoFactorRequirement.read_policy(site.id)
             end) == :error

      assert TwoFactorRequirement.policy(site.id).required_for == :everyone
      assert {:ok, %Policy{required_for: :everyone}} = TwoFactorRequirement.read_policy(site.id)
    end

    test "a site with no row is off", %{site: site} do
      assert TwoFactorRequirement.policy(site.id) == TwoFactorRequirement.off()
      assert TwoFactorRequirement.read_policy(site.id) == {:ok, TwoFactorRequirement.off()}
    end
  end

  describe "step_up/3" do
    test "an authenticator app is always the code prompt, policy or not", %{site: site} do
      admin = member!(totp_user(), site, :admin)

      assert TwoFactorRequirement.step_up(admin, site.id, policy: policy(:off)) == :totp
      assert TwoFactorRequirement.step_up(admin, site.id, policy: policy(:admins)) == :totp
    end

    test "a passkey-only account steps up with its passkey once enforced, not before", %{
      site: site
    } do
      admin = site |> then(&member!(user(), &1, :admin)) |> passkey!()
      opts = [policy: policy(:admins)]

      assert TwoFactorRequirement.step_up(admin, site.id, [now: at(13)] ++ opts) == :none
      assert TwoFactorRequirement.step_up(admin, site.id, [now: at(14)] ++ opts) == :passkey_only

      assert TwoFactorRequirement.step_up(admin, site.id, now: at(30), policy: policy(:off)) ==
               :none
    end

    test "an account with no factor has nothing to step up with", %{site: site} do
      admin = member!(user(), site, :admin)

      assert TwoFactorRequirement.step_up(admin, site.id, now: at(30), policy: policy(:admins)) ==
               :none
    end
  end

  describe "required_somewhere?/1" do
    test "only where a membership's tier is covered" do
      a = org("tfr-a")
      b = org("tfr-b")
      account = user() |> member!(a, :editor) |> member!(b, :viewer)

      refute TwoFactorRequirement.required_somewhere?(account)

      seed_policy(b, :admins)
      refute TwoFactorRequirement.required_somewhere?(account)

      seed_policy(a, :editors)
      assert TwoFactorRequirement.required_somewhere?(account)
    end

    test "an erased account is never required", %{site: site} do
      seed_policy(site, :everyone)
      erased = member!(user(%{anonymized_at: DateTime.utc_now()}), site, :viewer)

      refute TwoFactorRequirement.required_somewhere?(erased)
    end
  end

  describe "promotion_warning/4" do
    test "warns of an immediate hold, or of the grace, and not for an enrolled account", %{
      site: site
    } do
      long_standing = member!(user(), site, :viewer)
      newcomer = user(%{inserted_at: at(-1)})
      enrolled = site |> then(&member!(user(), &1, :viewer)) |> passkey!()
      opts = [policy: policy(:admins), now: at(30)]

      assert TwoFactorRequirement.promotion_warning(long_standing, site.id, :admin, opts) ==
               {:enforced_now, at(14)}

      assert TwoFactorRequirement.promotion_warning(newcomer, site.id, :admin, opts) ==
               {:grace, at(44)}

      assert TwoFactorRequirement.promotion_warning(enrolled, site.id, :admin, opts) == nil
      assert TwoFactorRequirement.promotion_warning(long_standing, site.id, :editor, opts) == nil
    end
  end

  describe "roster/3" do
    test "per covered tier: total, enrolled, in grace, overdue, earliest deadline", %{site: site} do
      member!(totp_user(), site, :admin)
      site |> then(&member!(user(), &1, :admin)) |> passkey!()
      member!(user(), site, :admin)
      member!(user(), site, :editor, %{inserted_at: at(10)})
      member!(user(), site, :editor)
      member!(user(), site, :viewer)
      member!(user(%{anonymized_at: DateTime.utc_now()}), site, :admin)

      roster = TwoFactorRequirement.roster(site.id, policy(:editors), now: at(20))

      assert Map.keys(roster) |> Enum.sort() == [:admin, :editor]

      assert roster.admin == %{
               total: 3,
               enrolled: 2,
               in_grace: 0,
               overdue: 1,
               earliest_deadline: nil
             }

      assert roster.editor == %{
               total: 2,
               enrolled: 0,
               in_grace: 1,
               overdue: 1,
               earliest_deadline: at(24)
             }
    end

    test "nothing when the policy is off", %{site: site} do
      member!(user(), site, :admin)
      assert TwoFactorRequirement.roster(site.id, policy(:off)) == %{}
    end
  end

  defp seed_policy(site, required_for) do
    covered = KilnCMS.CMS.SiteSecondFactorPolicy.covered_tiers(required_for)

    Ash.Seed.seed!(KilnCMS.CMS.SiteSecondFactorPolicy, %{
      org_id: site.id,
      required_for: required_for,
      grace_days: 14,
      admin_required_since: if(:admin in covered, do: @since),
      editor_required_since: if(:editor in covered, do: @since),
      viewer_required_since: if(:viewer in covered, do: @since),
      policy_changed_at: @since
    })

    KilnCMS.Cache.bust_second_factor_policy(site.id)
  end
end

defmodule KilnCMS.Accounts.TwoFactorRequirementDemoTest do
  @moduledoc """
  Demo mode and `KilnCMS.Accounts.TwoFactorRequirement` (#2247): an account
  whose credentials demo mode locks could never enrol, so it is never required
  to; demo admins still are.

  `async: false`: demo mode is `Application.put_env`, a process-wide write.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.TwoFactorRequirement
  alias KilnCMS.Accounts.TwoFactorRequirement.Policy

  setup do
    previous = Application.get_env(:kiln_cms, KilnCMS.Demo, [])
    Application.put_env(:kiln_cms, KilnCMS.Demo, Keyword.put(previous, :enabled, true))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Demo, previous) end)
    :ok
  end

  defp user(role) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "tfr-demo-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role,
      inserted_at: ~U[2026-01-01 00:00:00.000000Z]
    })
  end

  test "the shared demo account is never required; a demo admin is" do
    site = org("tfr-demo")
    since = ~U[2026-11-01 00:00:00.000000Z]

    policy = %Policy{
      required_for: :everyone,
      grace_days: 0,
      since: %{admin: since, editor: since, viewer: since}
    }

    shared = user(:editor)

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: site.id,
      user_id: shared.id,
      role: :editor
    })

    assert TwoFactorRequirement.status(shared, site.id, policy: policy) == :not_required
    assert TwoFactorRequirement.step_up(shared, site.id, policy: policy) == :none

    assert {:enforced, _} = TwoFactorRequirement.status(user(:admin), site.id, policy: policy)
  end
end
