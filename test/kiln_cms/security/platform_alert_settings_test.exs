defmodule KilnCMS.Security.PlatformAlertSettingsTest do
  @moduledoc """
  The platform's security alert settings (#2245, owner decision D-A):
  `api_key_rate_limited` is the one platform kind a platform admin can turn
  off. It starts on; turned off, its alert is stamped and nothing is sent,
  while every other platform kind still goes. Only platform admins can read
  or write the setting, and every save is in the instance security log.

  `async: false`: alerts are turned on (`KilnCMS.Test.SecurityAlerts.enable/0`,
  an `Application.put_env`), and the row is one for the whole installation.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.Notifications.Notification
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.Security.Alerts
  alias KilnCMS.Security.Recorder
  alias KilnCMS.Test.SecurityAlerts

  @moduletag :capture_log

  setup do
    SecurityAlerts.enable()

    org = org("platform-alerts")
    platform = user(:admin)

    %{
      org: org,
      platform: platform,
      site_admin: member!(user(:viewer), org.id, :admin),
      default_admin: member!(user(:viewer), Accounts.default_org_id(), :admin),
      editor: member!(user(:viewer), org.id, :editor)
    }
  end

  defp uniq, do: System.unique_integer([:positive])

  defp user(role) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "platform-alerts-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp member!(user, org_id, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org_id,
      user_id: user.id,
      role: role
    })

    user
  end

  defp turn_off!(actor, kinds \\ ["api_key_rate_limited"]),
    do: Security.save_platform_alert_settings!(%{disabled_kinds: kinds}, actor: actor)

  defp record!(type, org_id, metadata) do
    {:ok, _event} =
      Recorder.record(type,
        tenant: org_id,
        target_type: "api_key",
        target_id: Ecto.UUID.generate(),
        metadata: metadata
      )
  end

  defp rate_limited!(org_id),
    do: record!(:api_key_rate_limited, org_id, %{"name" => "ci", "bucket" => "api"})

  defp excerpts do
    Notification
    |> Repo.all()
    |> Enum.filter(&(&1.event == :security_alert))
    |> Enum.map(& &1.excerpt)
  end

  defp kind_dispatches(kind), do: Enum.filter(SecurityAlerts.dispatches(), &(&1["kind"] == kind))

  describe "api_key_rate_limited" do
    test "is on by default: a key over a rate limit reaches the platform admins", ctx do
      assert Alerts.platform_disabled_kinds() == []
      rate_limited!(ctx.org.id)
      SecurityAlerts.deliver()

      assert "An API key hit a rate limit" in excerpts()
    end

    test "turned off by a platform admin, sends nothing; the other API key kinds still go",
         ctx do
      turn_off!(ctx.platform)

      rate_limited!(ctx.org.id)
      record!(:api_key_reuse_detected, ctx.org.id, %{"name" => "ci", "revoked" => 2})
      record!(:api_key_created, ctx.org.id, %{"name" => "ci", "scope" => "read"})
      SecurityAlerts.deliver()

      # The window was claimed and stamped, with nothing sent for it.
      assert [%{"alert_sent_at" => %{}}] = kind_dispatches("api_key_rate_limited")

      excerpts = excerpts()
      refute "An API key hit a rate limit" in excerpts
      assert "A rotated API key was used again" in excerpts
      assert "An API key was created" in excerpts
    end

    test "turned back on, goes again", ctx do
      turn_off!(ctx.platform)
      turn_off!(ctx.platform, [])

      rate_limited!(ctx.org.id)
      SecurityAlerts.deliver()

      assert "An API key hit a rate limit" in excerpts()
    end

    test "a setting the delivery cannot read is treated as on", ctx do
      turn_off!(ctx.platform)
      assert Alerts.platform_enabled?(:api_key_rate_limited) == false

      assert Security.with_alerts_actor(nil, fn ->
               Alerts.platform_enabled?(:api_key_rate_limited)
             end)
    end

    test "every other platform kind is on without a read", ctx do
      turn_off!(ctx.platform)

      Security.with_alerts_actor(nil, fn ->
        for kind <- Alerts.platform_kinds() -- Alerts.platform_optional_kinds() do
          assert Alerts.platform_enabled?(kind), inspect(kind)
        end
      end)
    end
  end

  describe "who may change it" do
    test "a platform admin may, and the save is in the instance security log", ctx do
      row = turn_off!(ctx.platform)
      assert row.disabled_kinds == ["api_key_rate_limited"]

      # authorize?: false — reading the instance log back in a test.
      assert [event] =
               Security.list_instance_events!(authorize?: false)
               |> Enum.filter(&(&1.type == :platform_alerts_changed))

      assert event.actor_id == ctx.platform.id
      assert event.metadata == %{"disabled_kinds" => "api_key_rate_limited"}
    end

    test "only the optional kinds can be turned off", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               Security.save_platform_alert_settings(%{disabled_kinds: ["new_api_key"]},
                 actor: ctx.platform
               )

      assert Alerts.platform_disabled_kinds() == []
    end

    test "a site admin, the default site's admin and an editor are refused, read and write",
         ctx do
      turn_off!(ctx.platform)

      for actor <- [ctx.site_admin, ctx.default_admin, ctx.editor, nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Security.save_platform_alert_settings(%{disabled_kinds: []}, actor: actor)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Security.list_platform_alert_settings(actor: actor, authorize_with: :error)

        refute Security.can_save_platform_alert_settings?(actor, %{disabled_kinds: []})
      end

      assert Alerts.platform_disabled_kinds() == ["api_key_rate_limited"]
    end

    test "the alert delivery's actor may read it, and not save it", ctx do
      turn_off!(ctx.platform)

      assert {:ok, [_row]} =
               Security.list_platform_alert_settings(
                 actor: Security.alerts_system(),
                 authorize_with: :error
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Security.save_platform_alert_settings(%{disabled_kinds: []},
                 actor: Security.alerts_system()
               )
    end
  end
end
