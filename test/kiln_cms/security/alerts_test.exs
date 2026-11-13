defmodule KilnCMS.Security.AlertsTest do
  @moduledoc """
  `KilnCMS.Security.Alerts` (#2245): which events raise which alert kinds on
  which channel (`classify/2`, pure), the recipient rosters, the settings
  read, IP masking and the failed-sign-in tally.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Security
  alias KilnCMS.Security.Alerts
  alias KilnCMS.Security.AuthEvents
  alias KilnCMS.Test.BudgetWindow

  @moduletag :capture_log

  defp uniq, do: System.unique_integer([:positive])
  defp default_org, do: Accounts.default_org_id()

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.User,
      Map.merge(
        %{
          email: "alerts-#{role}-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp member!(user, org_id, role, attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.OrgMembership,
      Map.merge(%{organization_id: org_id, user_id: user.id, role: role}, attrs)
    )
  end

  defp later, do: DateTime.add(DateTime.utc_now(), 2, :hour)
  defp earlier, do: DateTime.add(DateTime.utc_now(), -2, :hour)

  defp event(type, metadata, attrs \\ %{}),
    do: Map.merge(%{type: type, metadata: metadata, actor_id: nil, target_id: nil}, attrs)

  defp ids(users), do: users |> Enum.map(& &1.id) |> MapSet.new()

  describe "classify/2: the kinds table" do
    test "an admin granted on a site is a site new_admin; on the platform a platform one" do
      assert Alerts.classify(event(:role_granted, %{"role" => "admin", "level" => "site"})) ==
               [{:new_admin, :site}]

      assert Alerts.classify(
               event(:role_granted, %{
                 "role" => "admin",
                 "previous_role" => "editor",
                 "level" => "platform"
               })
             ) == [{:new_admin, :platform}]
    end

    test "a temporary admin grant is a new admin at its own level" do
      assert Alerts.classify(
               event(:elevation_granted, %{"role" => "admin", "minutes" => 60, "level" => "site"})
             ) == [{:new_admin, :site}]

      assert Alerts.classify(
               event(:elevation_granted, %{"role" => "admin", "level" => "platform"})
             ) == [{:new_admin, :platform}]
    end

    test "a registration approved as admin is a site new_admin; at a lower tier, nothing" do
      assert Alerts.classify(event(:registration_approved, %{"role" => "admin", "via" => "x"})) ==
               [{:new_admin, :site}]

      assert Alerts.classify(event(:registration_approved, %{"role" => "editor"})) == []
    end

    test "a site raise below admin is a site role_elevation" do
      assert Alerts.classify(
               event(:role_granted, %{
                 "role" => "editor",
                 "previous_role" => "viewer",
                 "level" => "site"
               })
             ) == [{:role_elevation, :site}]

      assert Alerts.classify(event(:elevation_granted, %{"role" => "editor", "level" => "site"})) ==
               [{:role_elevation, :site}]
    end

    # The event's tenant is whichever site the platform admin was browsing:
    # a site kind here would tell that site's admins about an account that is
    # not theirs.
    test "a platform raise below admin is no alert" do
      assert Alerts.classify(
               event(:role_granted, %{
                 "role" => "editor",
                 "previous_role" => "viewer",
                 "level" => "platform"
               })
             ) == []

      assert Alerts.classify(
               event(:elevation_granted, %{"role" => "editor", "level" => "platform"})
             ) == []
    end

    test "a membership created at editor or viewer is not an elevation" do
      assert Alerts.classify(event(:role_granted, %{"role" => "editor", "level" => "site"})) == []
      assert Alerts.classify(event(:role_granted, %{"role" => "viewer", "level" => "site"})) == []
    end

    test "a legacy account's carried tier is not a grant" do
      assert Alerts.classify(
               event(:role_granted, %{
                 "role" => "admin",
                 "level" => "site",
                 "via" => "legacy_carry"
               })
             ) == []

      assert Alerts.classify(
               event(:elevation_granted, %{
                 "role" => "admin",
                 "level" => "site",
                 "via" => "legacy_carry"
               })
             ) == []
    end

    test "a platform admin's role taken away is platform_role_changed" do
      for change <- ["demoted", "grant_revoked"] do
        assert Alerts.classify(
                 event(:role_revoked, %{
                   "role" => "admin",
                   "level" => "platform",
                   "change" => change
                 })
               ) == [{:platform_role_changed, :platform}]
      end

      assert Alerts.classify(event(:role_revoked, %{"role" => "editor", "level" => "platform"})) ==
               []
    end

    test "failed sign-ins alert only on the event that carries the threshold flag" do
      e = event(:sign_in_failed, %{"method" => "password"})

      assert Alerts.classify(e) == []
      assert Alerts.classify(e, %{}) == []
      assert Alerts.classify(e, %{security_alert: :nope}) == []

      assert Alerts.classify(e, %{security_alert: {:threshold, 7, 10}}) ==
               [{:failed_sign_ins, :site}]
    end

    test "the one-to-one site kinds" do
      assert Alerts.classify(event(:sign_in_locked, %{})) == [{:lockout, :site}]

      assert Alerts.classify(event(:second_factor_removed, %{"kind" => "totp"})) ==
               [{:two_factor_disabled, :site}]

      assert Alerts.classify(event(:sso_config_changed, %{"provider" => "site_oidc"})) ==
               [{:sso_config_changed, :site}]
    end

    test "an invitee taking an account over does not raise two_factor_disabled (#2453)" do
      assert Alerts.classify(
               event(:second_factor_removed, %{"kind" => "totp", "via" => "invitation"})
             ) == []
    end

    test "a minted API key is a platform new_api_key; a rotation is nothing" do
      assert Alerts.classify(event(:api_key_created, %{"name" => "ci", "scope" => "read"})) ==
               [{:new_api_key, :platform}]

      assert Alerts.classify(
               event(:api_key_created, %{
                 "name" => "ci",
                 "scope" => "draft_write",
                 "via" => "rotate"
               })
             ) == []
    end

    test "a reused API key is platform api_key_abuse" do
      assert Alerts.classify(event(:api_key_reuse_detected, %{"name" => "ci", "revoked" => 2})) ==
               [{:api_key_abuse, :platform}]
    end

    test "unmapped types raise nothing" do
      for type <- [
            :sign_in,
            :member_invited,
            :passkey_removed,
            :recovery_code_used,
            :api_key_revoked,
            :admin_access_refused,
            :ip_auto_blocked
          ] do
        assert Alerts.classify(event(type, %{})) == [], "#{type} raised an alert"
      end

      assert Alerts.classify(event(:org_setting_changed, %{"setting" => "site_branding"})) == []
    end
  end

  describe "classify/2: notices derived from events" do
    setup do
      %{actor: Ecto.UUID.generate(), target: Ecto.UUID.generate()}
    end

    test "another person removing, demoting or ending a site admin's grant", ctx do
      for {change, notice} <- [
            {"removed", "admin_removed"},
            {"demoted", "admin_demoted"},
            {"grant_revoked", "admin_grant_revoked"}
          ] do
        e =
          event(:role_revoked, %{"role" => "admin", "level" => "site", "change" => change}, %{
            actor_id: ctx.actor,
            target_id: ctx.target
          })

        assert Alerts.classify(e) == [{:alerts_silenced, :notice, notice}]
      end
    end

    test "a self-demotion is no notice", ctx do
      e =
        event(:role_revoked, %{"role" => "admin", "level" => "site", "change" => "demoted"}, %{
          actor_id: ctx.actor,
          target_id: ctx.actor
        })

      assert Alerts.classify(e) == []
    end

    test "a change with nobody behind it is no notice", ctx do
      e =
        event(:role_revoked, %{"role" => "admin", "level" => "site", "change" => "removed"}, %{
          actor_id: nil,
          target_id: ctx.target
        })

      assert Alerts.classify(e) == []
    end

    test "a site editor taken away is no notice", ctx do
      e =
        event(:role_revoked, %{"role" => "editor", "level" => "site", "change" => "removed"}, %{
          actor_id: ctx.actor,
          target_id: ctx.target
        })

      assert Alerts.classify(e) == []
    end

    test "a change to the site's mail relay" do
      assert Alerts.classify(event(:org_setting_changed, %{"setting" => "site_mail_relay"})) ==
               [{:alerts_silenced, :notice, "mail_relay_changed"}]
    end
  end

  describe "classify/2 on recorded events" do
    defp ctx, do: AuthEvents.context(Plug.Test.conn(:get, "/"), default_org())

    defp recorded(type) do
      # authorize?: false — reading the log back in a test.
      Security.list_events!(tenant: default_org(), authorize?: false)
      |> Enum.filter(&(&1.type == type))
    end

    test "a membership created as admin raises a site new_admin" do
      admin = user(:admin)
      subject = user(:editor)

      {:ok, _} =
        Accounts.create_org_membership(
          %{organization_id: default_org(), user_id: subject.id, role: :admin},
          actor: admin,
          context: ctx()
        )

      assert [event] = recorded(:role_granted)
      assert Alerts.classify(event) == [{:new_admin, :site}]
    end

    test "an account made admin raises a platform new_admin" do
      admin = user(:admin)
      subject = user(:editor)

      {:ok, _} =
        Accounts.manage_user_access(subject, %{role: :admin}, actor: admin, context: ctx())

      assert [event] = recorded(:role_granted)
      assert Alerts.classify(event) == [{:new_admin, :platform}]
    end

    test "removing a member whose admin tier is a live grant raises the notice (W1)" do
      admin = user(:admin)
      subject = user(:editor)

      membership =
        member!(subject, default_org(), :editor, %{
          granted_role: :admin,
          granted_role_expires_at: later()
        })

      :ok = Accounts.remove_org_membership(membership, actor: admin, context: ctx())

      assert [event] = recorded(:role_revoked)
      assert Alerts.classify(event) == [{:alerts_silenced, :notice, "admin_removed"}]
    end

    test "a legacy account carried onto the default org raises nothing" do
      admin = user(:admin)

      legacy =
        user(:admin, %{role: :editor, granted_role: :admin, granted_role_expires_at: later()})

      {:ok, _} =
        Accounts.LegacyAffiliation.ensure_default_membership(legacy, actor: admin, context: ctx())

      events = recorded(:role_granted) ++ recorded(:elevation_granted)
      assert length(events) == 2
      assert Enum.flat_map(events, &Alerts.classify/1) == []
    end
  end

  describe "kinds and webhook events" do
    test "site webhook events, the notice, and no platform kind (B1)" do
      events = Alerts.webhook_events()

      assert "security.new_admin" in events
      assert "security.failed_sign_ins" in events
      assert "security.alerts_silenced" in events
      refute "security.new_api_key" in events
      refute "security.api_key_abuse" in events
      refute "security.platform_role_changed" in events
      assert length(events) == length(Alerts.site_kinds()) + 1
    end
  end

  describe "rosters" do
    test "site recipients are the site's member admins, literally" do
      org = org("alerts-roster")

      member_admin = user(:viewer)
      member!(member_admin, org.id, :admin)

      temp_admin = user(:viewer)

      member!(temp_admin, org.id, :editor, %{
        granted_role: :admin,
        granted_role_expires_at: later()
      })

      lapsed = user(:viewer)

      member!(lapsed, org.id, :editor, %{granted_role: :admin, granted_role_expires_at: earlier()})

      editor = user(:viewer)
      member!(editor, org.id, :editor)

      pending = user(:viewer)
      member!(pending, org.id, :admin, %{status: :pending})

      platform_member = user(:admin)
      member!(platform_member, org.id, :admin)

      erased = user(:viewer, %{anonymized_at: DateTime.utc_now()})
      member!(erased, org.id, :admin)

      elsewhere = user(:viewer)
      member!(elsewhere, default_org(), :admin)

      _platform = user(:admin)

      assert ids(Alerts.site_recipients(org.id)) == ids([member_admin, temp_admin])
      assert Alerts.member_admins?(org.id)
    end

    test "a site with no member admins falls back to the platform admins (OC-1)" do
      platform = user(:admin)
      empty = org("alerts-empty")

      refute Alerts.member_admins?(empty.id)
      assert ids(Alerts.site_recipients(empty.id)) == ids(Alerts.platform_recipients())
      assert platform.id in Enum.map(Alerts.site_recipients(empty.id), & &1.id)
    end

    test "platform recipients are every platform admin, temporary included, erased excluded" do
      standing = user(:admin)
      temporary = user(:editor, %{granted_role: :admin, granted_role_expires_at: later()})
      lapsed = user(:editor, %{granted_role: :admin, granted_role_expires_at: earlier()})
      erased = user(:admin, %{anonymized_at: DateTime.utc_now()})
      editor = user(:editor)

      got = ids(Alerts.platform_recipients())

      assert MapSet.subset?(ids([standing, temporary]), got)
      assert MapSet.disjoint?(ids([lapsed, erased, editor]), got)
    end

    test "member_admin_anywhere?/1" do
      org = org("alerts-anywhere")
      member_admin = user(:viewer)
      member!(member_admin, org.id, :admin)

      editor = user(:viewer)
      member!(editor, org.id, :editor)

      platform = user(:admin)
      member!(platform, org.id, :admin)

      assert Alerts.member_admin_anywhere?(member_admin)
      refute Alerts.member_admin_anywhere?(editor)
      refute Alerts.member_admin_anywhere?(platform)
      refute Alerts.member_admin_anywhere?(nil)
    end
  end

  describe "settings_for/1 and display_ip/2" do
    test "defaults without a row; the row once saved" do
      org = org("alerts-settings")
      admin = user(:viewer)
      member!(admin, org.id, :admin)

      assert Alerts.settings_for(org.id) == %{
               disabled_kinds: ["failed_sign_ins"],
               notify_admins: true,
               include_full_ip: false
             }

      {:ok, _} =
        CMS.save_site_security_alerts(
          %{disabled_kinds: ["lockout"], notify_admins: false, include_full_ip: true},
          actor: admin,
          tenant: org.id
        )

      assert Alerts.settings_for(org.id) == %{
               disabled_kinds: ["lockout"],
               notify_admins: false,
               include_full_ip: true
             }
    end

    test "an unreadable row is logged and answered with every kind on, masked" do
      org = org("alerts-unreadable")

      settings =
        KilnCMS.OrgSettings.with_actor(nil, fn -> Alerts.settings_for(org.id) end)

      assert settings == %{disabled_kinds: [], notify_admins: true, include_full_ip: false}
      assert settings == Alerts.unreadable_settings()
      assert Alerts.enabled?(settings, :failed_sign_ins)
    end

    test "an address is masked unless the site opted in, and always on the platform" do
      assert Alerts.display_ip("203.0.113.7", Alerts.defaults()) == "203.0.113.0/24"
      assert Alerts.display_ip("203.0.113.7", %{include_full_ip: true}) == "203.0.113.7"
      assert Alerts.display_ip("2001:db8:1:2::9", nil) == "2001:db8:1::/48"
      assert Alerts.display_ip(nil, %{include_full_ip: true}) == nil
    end
  end

  describe "charge_failed_sign_in/2" do
    test "counts nothing while the kind is off, which is the default" do
      org = org("alerts-tally-off")
      assert Alerts.charge_failed_sign_in(org.id) == :off
    end

    test "once on, the threshold-th failure in a window is the one that alerts" do
      org = org("alerts-tally-on")
      admin = user(:viewer)
      member!(admin, org.id, :admin)

      # Cached as off first, so the save must bust it.
      assert Alerts.charge_failed_sign_in(org.id) == :off

      {:ok, _} =
        CMS.save_site_security_alerts(%{disabled_kinds: []}, actor: admin, tenant: org.id)

      window = BudgetWindow.fresh_window_ms()
      threshold = Alerts.failed_sign_in_threshold()

      results =
        for _ <- 1..(threshold + 5), do: Alerts.charge_failed_sign_in(org.id, window_ms: window)

      assert [{:threshold, idx, ^threshold}] =
               Enum.filter(results, &match?({:threshold, _, _}, &1))

      assert Enum.count(results, &(&1 == :counted)) == threshold + 4

      assert Alerts.failed_sign_in_total(org.id, idx) == threshold + 5

      # Another site's tally is its own.
      other = org("alerts-tally-other")
      assert Alerts.charge_failed_sign_in(other.id, window_ms: window) == :off
    end

    test "settings that cannot be read count, failing toward the alert" do
      org = org("alerts-tally-unreadable")

      result =
        KilnCMS.OrgSettings.with_actor(nil, fn ->
          Alerts.charge_failed_sign_in(org.id, window_ms: BudgetWindow.fresh_window_ms())
        end)

      assert result == :counted
    end
  end
end

defmodule KilnCMS.Security.AlertsFallbackTripTest do
  @moduledoc """
  `Alerts.charge_failed_sign_in/2` across a database outage (#2639): a
  crossing counted only on this node's fallback must not use up the window's
  shared crossing, or the alert is never claimed once the database is back.

  Sync and not a `DataCase`: the database is made unreachable by leaving the
  sandbox in `:manual` without a checkout, and the fallback table is
  node-wide.
  """
  use ExUnit.Case, async: false

  import KilnCMS.OrgFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Security.Alerts
  alias KilnCMS.Test.BudgetWindow

  @moduletag :capture_log

  setup do
    Sandbox.mode(KilnCMS.Repo, :manual)
    on_exit(fn -> Sandbox.mode(KilnCMS.Repo, :manual) end)
    :ok
  end

  test "a crossing on the node's fallback leaves the database's crossing to claim" do
    org_id = Ash.UUID.generate()
    window = BudgetWindow.fresh_window_ms()
    threshold = Alerts.failed_sign_in_threshold()

    # The database is down: the settings cannot be read, which counts, and the
    # tally counts on this node.
    down = for _ <- 1..threshold, do: Alerts.charge_failed_sign_in(org_id, window_ms: window)
    assert [{:threshold, idx, ^threshold}] = Enum.filter(down, &match?({:threshold, _, _}, &1))

    # It is back, in the same window: its own tally reaches the threshold too.
    :ok = Sandbox.checkout(KilnCMS.Repo)
    on_exit(fn -> Sandbox.checkin(KilnCMS.Repo) end)

    org = org("alerts-fallback-trip", id: org_id)

    admin =
      Ash.Seed.seed!(Accounts.User, %{
        email: "alerts-trip-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org.id,
      user_id: admin.id,
      role: :admin
    })

    {:ok, _} = CMS.save_site_security_alerts(%{disabled_kinds: []}, actor: admin, tenant: org.id)

    up = for _ <- 1..threshold, do: Alerts.charge_failed_sign_in(org_id, window_ms: window)
    assert [{:threshold, ^idx, ^threshold}] = Enum.filter(up, &match?({:threshold, _, _}, &1))
  end
end
