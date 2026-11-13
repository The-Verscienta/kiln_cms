defmodule KilnCMS.CMS.SiteSecondFactorPolicyTest do
  @moduledoc """
  The `SiteSecondFactorPolicy` resource (#2247): who may read and write it, the
  guard that every person's write needs that person's own verified second
  factor (on `:save` and `:update` alike), the per-tier "required since"
  stamps, the audit event, the after-commit announcement, and the operator's
  override, which only the `:operator` system actor may run.

  Each test seeds its own sites, so nothing here can leak a cached policy into
  the default org another test is signing in to. Wrong codes spend the real
  default budget (five) of a fresh account, so no `Application.put_env`.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.TwoFactorRequirement
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Changes.SaverVerifiedSecondFactor
  alias KilnCMS.Security
  alias KilnCMS.TwoFactorFixtures

  @messages SaverVerifiedSecondFactor.messages()

  setup do
    site = org("sfp")
    {admin, secret} = totp_member(site, :admin)
    %{site: site, admin: admin, secret: secret}
  end

  defp user(role \\ :viewer) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "sfp-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp member!(user, org, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org.id,
      user_id: user.id,
      role: role
    })

    user
  end

  defp totp_member(site, role) do
    {user, secret} =
      TwoFactorFixtures.enabled_user(
        role: :viewer,
        email: "sfp-totp-#{System.unique_integer([:positive])}@example.com"
      )

    {member!(user, site, role), secret}
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

  defp verified(at \\ DateTime.utc_now()), do: %{second_factor_verified_at: at}

  defp save(attrs, actor, site, context \\ verified()) do
    CMS.save_site_second_factor_policy(attrs, actor: actor, tenant: site.id, context: context)
  end

  defp stored(site) do
    case CMS.list_site_second_factor_policy(
           actor: KilnCMS.SystemActor.new(:operator),
           tenant: site.id,
           authorize_with: :error
         ) do
      {:ok, [row]} -> row
      {:ok, []} -> nil
    end
  end

  defp events(site, type) do
    Security.list_events!(actor: user(:admin), tenant: site.id, page: [limit: 50])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == type))
  end

  defp code_errors({:error, %{errors: errors}}) do
    for %{field: :code} = error <- errors, do: error.message
  end

  defp code_errors(_other), do: []

  describe "who may read and write it" do
    test "an editor, a viewer and an anonymous caller are refused, and nothing is stored", %{
      site: site
    } do
      for actor <- [
            member!(user(), site, :editor) |> passkey!(),
            member!(user(), site, :viewer) |> passkey!(),
            nil
          ] do
        assert {:error, %Ash.Error.Forbidden{}} = save(%{required_for: :admins}, actor, site)
      end

      assert stored(site) == nil
    end

    test "editors and viewers cannot read it; the admin can", %{site: site, admin: admin} do
      assert {:ok, _} = save(%{required_for: :admins}, admin, site)

      for role <- [:editor, :viewer] do
        actor = member!(user(), site, role)

        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.list_site_second_factor_policy(
                   actor: actor,
                   tenant: site.id,
                   authorize_with: :error
                 )
      end

      assert {:ok, [%{required_for: :admins}]} =
               CMS.list_site_second_factor_policy(actor: admin, tenant: site.id)
    end

    test "the admin of another site can neither read nor save this site's row", %{
      site: site,
      admin: admin
    } do
      assert {:ok, _} = save(%{required_for: :admins, grace_days: 7}, admin, site)

      other = org("sfp-other")
      {other_admin, _secret} = totp_member(other, :admin)

      assert {:error, %Ash.Error.Forbidden{}} = save(%{required_for: :off}, other_admin, site)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.list_site_second_factor_policy(
                 actor: other_admin,
                 tenant: site.id,
                 authorize_with: :error
               )

      assert %{required_for: :admins, grace_days: 7} = stored(site)
    end

    test "a platform admin with a verified factor may save it", %{site: site} do
      platform = user(:admin) |> passkey!()

      assert {:ok, %{required_for: :everyone}} = save(%{required_for: :everyone}, platform, site)
    end

    test "no one may destroy it, an admin included: off is a save", %{site: site, admin: admin} do
      assert {:ok, row} = save(%{required_for: :admins}, admin, site)

      refute Ash.can?({row, :destroy}, admin, tenant: site.id)
      refute Ash.can?({row, :destroy}, user(:admin), tenant: site.id)
      assert %{required_for: :admins} = stored(site)
    end
  end

  describe "the saver's own second factor" do
    test "an admin with no second factor is refused, even with a verified mark", %{site: site} do
      admin = member!(user(), site, :admin)

      result = save(%{required_for: :admins}, admin, site)

      assert code_errors(result) == [@messages.not_enrolled]
      assert stored(site) == nil
    end

    test "an unenrolled admin cannot weaken the policy, and the row is unchanged", %{
      site: site,
      admin: admin
    } do
      assert {:ok, _} = save(%{required_for: :everyone, grace_days: 7}, admin, site)

      unenrolled = member!(user(), site, :admin)

      result = save(%{required_for: :off, grace_days: 7}, unenrolled, site)

      assert code_errors(result) == [@messages.not_enrolled]
      assert %{required_for: :everyone, grace_days: 7} = stored(site)
    end

    test "an authenticator holder with no mark and no code is refused", %{
      site: site,
      admin: admin
    } do
      result = save(%{required_for: :admins}, admin, site, %{})

      assert code_errors(result) == [@messages.not_verified]
      assert stored(site) == nil
    end

    test "a correct code is accepted", %{site: site, admin: admin, secret: secret} do
      code = TwoFactorFixtures.current_code(secret)

      assert {:ok, %{required_for: :admins}} =
               save(%{required_for: :admins, code: code}, admin, site, %{})
    end

    test "a wrong code is refused, and the row is unchanged", %{site: site, admin: admin} do
      result = save(%{required_for: :admins, code: "000000"}, admin, site, %{})

      assert code_errors(result) == [@messages.wrong_code]
      assert stored(site) == nil
    end

    test "a verdict a caller puts in the context is not a verified code", %{
      site: site,
      admin: admin
    } do
      # The guard's own key is not an atom, so Ash will not even accept it as
      # caller context; the old atom key must not be read either.
      result =
        save(%{required_for: :admins}, admin, site, %{second_factor_code_verdict: :verified})

      assert code_errors(result) == [@messages.not_verified]

      assert stored(site) == nil
    end

    test "a fresh verified mark is accepted, up to 15 minutes old", %{site: site, admin: admin} do
      at = ~U[2026-11-13 10:00:00.000000Z]
      now = DateTime.add(at, SaverVerifiedSecondFactor.fresh_seconds(), :second)

      assert {:ok, _} =
               save(%{required_for: :admins}, admin, site, %{
                 second_factor_verified_at: at,
                 now: now
               })
    end

    test "a stale verified mark is refused", %{site: site, admin: admin} do
      at = ~U[2026-11-13 10:00:00.000000Z]
      now = DateTime.add(at, SaverVerifiedSecondFactor.fresh_seconds() + 1, :second)

      result =
        save(%{required_for: :off}, admin, site, %{second_factor_verified_at: at, now: now})

      assert code_errors(result) == [@messages.not_verified]
      assert stored(site) == nil
    end

    test "a mark from the future is refused", %{site: site, admin: admin} do
      now = ~U[2026-11-13 10:00:00.000000Z]
      at = DateTime.add(now, 10, :minute)

      result =
        save(%{required_for: :admins}, admin, site, %{second_factor_verified_at: at, now: now})

      assert code_errors(result) == [@messages.not_verified]
    end

    test "a passkey-only admin is accepted with the mark and refused without it", %{site: site} do
      admin = member!(user(), site, :admin) |> passkey!()

      result = save(%{required_for: :admins, code: "123456"}, admin, site, %{})
      assert code_errors(result) == [@messages.not_verified]

      assert {:ok, _} = save(%{required_for: :admins}, admin, site)
    end

    test "the actor is re-read: a struct that still shows a removed factor does not count", %{
      site: site,
      admin: admin
    } do
      Ash.Seed.update!(admin, %{totp_confirmed_at: nil, totp_secret: nil})

      result = save(%{required_for: :admins}, admin, site)
      assert code_errors(result) == [@messages.not_enrolled]
    end

    test ":update is guarded as :save is", %{site: site, admin: admin} do
      assert {:ok, row} = save(%{required_for: :everyone}, admin, site)

      unenrolled = member!(user(), site, :admin)

      result =
        CMS.update_site_second_factor_policy(row, %{required_for: :off},
          actor: unenrolled,
          tenant: site.id,
          context: verified()
        )

      assert code_errors(result) == [@messages.not_enrolled]

      result =
        CMS.update_site_second_factor_policy(row, %{required_for: :off},
          actor: admin,
          tenant: site.id
        )

      assert code_errors(result) == [@messages.not_verified]
      assert %{required_for: :everyone} = stored(site)

      assert {:ok, %{required_for: :off}} =
               CMS.update_site_second_factor_policy(row, %{required_for: :off},
                 actor: admin,
                 tenant: site.id,
                 context: verified()
               )
    end
  end

  describe "the required-since stamps" do
    test "off → admins → editors (and a longer grace) → admins → off", %{
      site: site,
      admin: admin
    } do
      t0 = ~U[2026-11-01 09:00:00.000000Z]
      t1 = ~U[2026-11-02 09:00:00.000000Z]
      t2 = ~U[2026-11-03 09:00:00.000000Z]
      t3 = ~U[2026-11-04 09:00:00.000000Z]
      at = fn now -> %{second_factor_verified_at: now, now: now} end

      assert {:ok, row} = save(%{required_for: :admins, grace_days: 14}, admin, site, at.(t0))
      assert {row.admin_required_since, row.editor_required_since} == {t0, nil}
      assert row.viewer_required_since == nil
      assert row.policy_changed_at == t0

      assert {:ok, row} = save(%{required_for: :editors, grace_days: 30}, admin, site, at.(t1))
      assert {row.admin_required_since, row.editor_required_since} == {t0, t1}
      assert row.policy_changed_at == t1

      assert {:ok, row} = save(%{required_for: :admins, grace_days: 30}, admin, site, at.(t2))
      assert {row.admin_required_since, row.editor_required_since} == {t0, nil}

      assert {:ok, row} = save(%{required_for: :off, grace_days: 30}, admin, site, at.(t3))

      assert {row.admin_required_since, row.editor_required_since, row.viewer_required_since} ==
               {nil, nil, nil}

      assert row.policy_changed_at == t3
    end
  end

  describe "the audit event" do
    test "one second_factor_policy_changed per write, none generic", %{site: site, admin: admin} do
      assert {:ok, row} = save(%{required_for: :editors, grace_days: 14}, admin, site)
      assert {:ok, _} = save(%{required_for: :admins, grace_days: 30}, admin, site)
      assert {:ok, _} = save(%{required_for: :everyone, grace_days: 7}, admin, site)
      assert {:ok, _} = save(%{required_for: :everyone, grace_days: 7}, admin, site)

      events =
        site |> events(:second_factor_policy_changed) |> Enum.sort_by(& &1.inserted_at, DateTime)

      assert Enum.map(events, & &1.metadata) == [
               %{
                 "required_for" => "editors",
                 "grace_days" => 14,
                 "previous_required_for" => "off",
                 "change" => "strengthened",
                 "via" => "admin"
               },
               %{
                 "required_for" => "admins",
                 "grace_days" => 30,
                 "previous_required_for" => "editors",
                 "change" => "weakened",
                 "via" => "admin"
               },
               %{
                 "required_for" => "everyone",
                 "grace_days" => 7,
                 "previous_required_for" => "admins",
                 "change" => "strengthened",
                 "via" => "admin"
               },
               %{
                 "required_for" => "everyone",
                 "grace_days" => 7,
                 "previous_required_for" => "everyone",
                 "change" => "unchanged",
                 "via" => "admin"
               }
             ]

      assert Enum.all?(events, &(&1.actor_id == admin.id))
      assert Enum.all?(events, &(&1.target_id == row.id))
      assert events(site, :org_setting_changed) == []
    end

    test "a refused write records nothing", %{site: site} do
      unenrolled = member!(user(), site, :admin)
      assert {:error, _} = save(%{required_for: :off}, unenrolled, site)
      assert events(site, :second_factor_policy_changed) == []
    end
  end

  describe "after commit" do
    test "a save is announced to the site's pages and reaches policy/1", %{
      site: site,
      admin: admin
    } do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, TwoFactorRequirement.topic(site.id))
      assert TwoFactorRequirement.policy(site.id).required_for == :off

      assert {:ok, _} = save(%{required_for: :editors, grace_days: 3}, admin, site)

      assert_receive {:second_factor_policy_changed,
                      %TwoFactorRequirement.Policy{required_for: :editors, grace_days: 3}}

      assert TwoFactorRequirement.policy(site.id).required_for == :editors
    end

    test "a refused write announces nothing", %{site: site} do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, TwoFactorRequirement.topic(site.id))
      unenrolled = member!(user(), site, :admin)

      assert {:error, _} = save(%{required_for: :admins}, unenrolled, site)
      refute_receive {:second_factor_policy_changed, _}
    end
  end

  describe "the operator's override" do
    test "only the :operator system actor may run it; it turns the policy off and is logged", %{
      site: site,
      admin: admin
    } do
      assert {:ok, row} = save(%{required_for: :everyone, grace_days: 7}, admin, site)

      for actor <- [admin, user(:admin) |> passkey!(), KilnCMS.SystemActor.new(:accounts), nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.override_site_second_factor_policy(row,
                   actor: actor,
                   tenant: site.id,
                   context: verified()
                 )
      end

      assert %{required_for: :everyone} = stored(site)

      Phoenix.PubSub.subscribe(KilnCMS.PubSub, TwoFactorRequirement.topic(site.id))

      assert {:ok, row} =
               CMS.override_site_second_factor_policy(row,
                 actor: KilnCMS.SystemActor.new(:operator),
                 tenant: site.id
               )

      assert row.required_for == :off
      assert row.grace_days == 7

      assert {row.admin_required_since, row.editor_required_since, row.viewer_required_since} ==
               {nil, nil, nil}

      assert_receive {:second_factor_policy_changed, %{required_for: :off}}

      assert [event] =
               site
               |> events(:second_factor_policy_changed)
               |> Enum.filter(&(&1.metadata["via"] == "console"))

      assert event.actor_id == nil

      assert event.metadata == %{
               "required_for" => "off",
               "grace_days" => 7,
               "previous_required_for" => "everyone",
               "change" => "weakened",
               "via" => "console"
             }
    end

    test "the :operator system actor may not run :save", %{site: site} do
      assert {:error, %Ash.Error.Forbidden{}} =
               save(%{required_for: :off}, KilnCMS.SystemActor.new(:operator), site)
    end
  end
end
