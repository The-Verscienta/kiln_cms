defmodule KilnCMS.Security.NoticesTest do
  @moduledoc """
  `alerts_silenced` notices (#2245): turning a site's alerts quieter — in its
  alert settings, or on a webhook endpoint subscribed to security events —
  always tells the site's member admins, muted or not, and nobody else.
  Turning a platform alert off tells every platform admin (#2811).

  `async: false`: alerts are turned on for the delivery
  (`KilnCMS.Test.SecurityAlerts.enable/0`, an `Application.put_env`).
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Notifications
  alias KilnCMS.Notifications.Notification
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.Test.SecurityAlerts

  @moduletag :capture_log

  setup do
    SecurityAlerts.enable()

    org = org("notices")
    other = org("notices-b")
    admin = member!(user(), org.id, :admin)
    muted = member!(user(%{notify_on_security_alert: false}), org.id, :admin)
    editor = member!(user(), org.id, :editor)
    other_admin = member!(user(), other.id, :admin)

    %{org: org, admin: admin, muted: muted, editor: editor, other_admin: other_admin}
  end

  defp uniq, do: System.unique_integer([:positive])

  defp user(attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.User,
      Map.merge(
        %{
          email: "notices-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :viewer
        },
        attrs
      )
    )
  end

  defp member!(user, org_id, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org_id,
      user_id: user.id,
      role: role
    })

    user
  end

  defp notices, do: Enum.map(SecurityAlerts.dispatches(), & &1["notice"])
  defp changes, do: Enum.map(notices(), & &1["change"])

  defp save(ctx, attrs),
    do: CMS.save_site_security_alerts(attrs, actor: ctx.admin, tenant: ctx.org.id)

  defp endpoint!(ctx, events) do
    CMS.create_webhook_endpoint!(
      %{url: "https://hooks.example.com/#{uniq()}", events: events},
      actor: ctx.admin,
      tenant: ctx.org.id
    )
  end

  describe "settings" do
    test "turning a kind off tells every member admin, muted or not, and nobody else", ctx do
      {:ok, _} = save(ctx, %{disabled_kinds: ["failed_sign_ins", "lockout"]})

      assert [notice] = notices()

      assert notice == %{
               "change" => "kind_disabled",
               "kinds" => ["lockout"],
               "actor_id" => ctx.admin.id
             }

      SecurityAlerts.deliver()

      users = Notification |> Repo.all() |> Enum.map(& &1.user_id) |> MapSet.new()
      assert users == MapSet.new([ctx.admin.id, ctx.muted.id])

      Oban.drain_queue(queue: :mail)
      assert_received {:email, %{to: [{_, to_a}]} = mail}
      assert_received {:email, %{to: [{_, to_b}]}}

      assert MapSet.new([to_a, to_b]) ==
               MapSet.new([to_string(ctx.admin.email), to_string(ctx.muted.email)])

      assert mail.html_body =~ "cannot be muted"
      refute_received {:email, _}
    end

    test "turning admin notifications off says so", ctx do
      {:ok, _} = save(ctx, %{notify_admins: false})
      assert changes() == ["admin_notifications_off"]
    end

    test "turning things back on, opting into full addresses, or saving unchanged says nothing",
         ctx do
      {:ok, _} = save(ctx, %{disabled_kinds: ["failed_sign_ins", "lockout"]})
      Repo.query!("DELETE FROM security_alert_dispatches")

      {:ok, _} = save(ctx, %{disabled_kinds: ["failed_sign_ins", "lockout"]})
      {:ok, _} = save(ctx, %{disabled_kinds: []})
      # The whole form, as the page submits it: a `:save` upsert writes the
      # default for a field left out, and a left-out `disabled_kinds` is
      # `["failed_sign_ins"]` — a kind turned off, which would be a notice.
      {:ok, _} = save(ctx, %{disabled_kinds: [], include_full_ip: true, notify_admins: true})

      assert notices() == []
    end

    test "a reset while failed sign-ins were on turns them off, and says so", ctx do
      {:ok, row} = save(ctx, %{disabled_kinds: []})
      Repo.query!("DELETE FROM security_alert_dispatches")

      :ok = CMS.reset_site_security_alerts(row, actor: ctx.admin, tenant: ctx.org.id)

      assert [%{"change" => "kind_disabled", "kinds" => ["failed_sign_ins"]}] = notices()
    end

    test "a refused save sends no notice", ctx do
      assert {:error, _} = save(ctx, %{disabled_kinds: ["lockout", "made_up"]})

      assert {:error, _} =
               CMS.save_site_security_alerts(%{disabled_kinds: ["lockout"]},
                 actor: ctx.editor,
                 tenant: ctx.org.id
               )

      assert notices() == []
    end
  end

  describe "webhook endpoints" do
    test "an endpoint subscribed to security events: every silencing change is a notice", ctx do
      endpoint = endpoint!(ctx, ["security.lockout", "page.published"])

      endpoint =
        CMS.update_webhook_endpoint!(endpoint, %{url: "https://elsewhere.example.com/x"},
          actor: ctx.admin,
          tenant: ctx.org.id
        )

      endpoint =
        CMS.update_webhook_endpoint!(endpoint, %{events: ["security.lockout"]},
          actor: ctx.admin,
          tenant: ctx.org.id
        )

      assert changes() == ["webhook_changed"]

      endpoint =
        CMS.update_webhook_endpoint!(endpoint, %{events: ["page.published"]},
          actor: ctx.admin,
          tenant: ctx.org.id
        )

      endpoint =
        CMS.update_webhook_endpoint!(endpoint, %{events: ["security.lockout"]},
          actor: ctx.admin,
          tenant: ctx.org.id
        )

      {:ok, endpoint} =
        CMS.rotate_webhook_secret(endpoint, actor: ctx.admin, tenant: ctx.org.id)

      :ok = CMS.destroy_webhook_endpoint(endpoint, actor: ctx.admin, tenant: ctx.org.id)

      assert changes() == [
               "webhook_changed",
               "webhook_changed",
               "webhook_secret_rotated",
               "webhook_removed"
             ]

      assert Enum.all?(notices(), &(&1["endpoint_id"] == endpoint.id))
      assert Enum.all?(notices(), &(&1["actor_id"] == ctx.admin.id))
      refute inspect(SecurityAlerts.dispatches()) =~ "example.com"
    end

    test "switching one off by hand, or the pipeline auto-disabling it, is a notice", ctx do
      endpoint = endpoint!(ctx, ["security.new_admin"])

      CMS.update_webhook_endpoint!(endpoint, %{active: false},
        actor: ctx.admin,
        tenant: ctx.org.id
      )

      failing = endpoint!(ctx, ["security.alerts_silenced"])
      failing = Ash.Seed.update!(failing, %{consecutive_failures: 100})

      CMS.record_webhook_failure!(failing,
        actor: KilnCMS.Webhooks.system(),
        tenant: ctx.org.id
      )

      assert changes() == ["webhook_changed", "webhook_auto_disabled"]
      assert List.last(notices())["actor_id"] == nil
    end

    # #2737: decided on the row, not on the caller's copy of the endpoint.
    test "auto-disabling is one notice, however stale the callers' copies", ctx do
      endpoint = endpoint!(ctx, ["security.alerts_silenced"])
      stale = Ash.Seed.update!(endpoint, %{consecutive_failures: 100})
      opts = [actor: KilnCMS.Webhooks.system(), tenant: ctx.org.id]

      CMS.record_webhook_failure!(stale, opts)
      CMS.record_webhook_failure!(stale, opts)

      assert changes() == ["webhook_auto_disabled"]
    end

    test "a stale copy past the threshold does not switch off a reset endpoint", ctx do
      endpoint = endpoint!(ctx, ["security.alerts_silenced"])
      stale = Ash.Seed.update!(endpoint, %{consecutive_failures: 100})
      opts = [actor: KilnCMS.Webhooks.system(), tenant: ctx.org.id]
      CMS.record_webhook_success!(stale, opts)

      assert CMS.record_webhook_failure!(stale, opts).active
      assert changes() == []
    end

    test "an endpoint not subscribed to security events changes silently", ctx do
      endpoint = endpoint!(ctx, ["page.published"])

      endpoint =
        CMS.update_webhook_endpoint!(endpoint, %{url: "https://elsewhere.example.com/y"},
          actor: ctx.admin,
          tenant: ctx.org.id
        )

      {:ok, endpoint} =
        CMS.rotate_webhook_secret(endpoint, actor: ctx.admin, tenant: ctx.org.id)

      :ok = CMS.destroy_webhook_endpoint(endpoint, actor: ctx.admin, tenant: ctx.org.id)

      assert notices() == []
    end

    test "subscribing to more, or switching back on, says nothing", ctx do
      endpoint = endpoint!(ctx, ["security.lockout"])

      CMS.update_webhook_endpoint!(
        endpoint,
        %{events: ["security.lockout", "security.new_admin"]},
        actor: ctx.admin,
        tenant: ctx.org.id
      )

      assert notices() == []
    end
  end

  describe "platform alert settings (#2811)" do
    setup ctx do
      default_org_id = Accounts.default_org_id()

      platform = user(%{role: :admin})
      muted_platform = user(%{role: :admin, notify_on_security_alert: false})

      temporary_platform =
        user(%{
          role: :editor,
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      expired_platform =
        user(%{
          role: :editor,
          granted_role: :admin,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      erased_platform = user(%{role: :admin, anonymized_at: DateTime.utc_now()})
      default_admin = member!(user(), default_org_id, :admin)
      default_editor = member!(user(), default_org_id, :editor)

      # A default-org endpoint subscribed to notices: a platform notice is
      # not a webhook event, so it must hear nothing.
      CMS.create_webhook_endpoint!(
        %{url: "https://hooks.example.com/#{uniq()}", events: ["security.alerts_silenced"]},
        actor: default_admin,
        tenant: default_org_id
      )

      Repo.query!("DELETE FROM security_alert_dispatches")

      Map.merge(ctx, %{
        default_org_id: default_org_id,
        platform: platform,
        muted_platform: muted_platform,
        temporary_platform: temporary_platform,
        refused: [
          expired_platform,
          erased_platform,
          default_admin,
          default_editor,
          ctx.admin,
          ctx.muted,
          ctx.editor,
          ctx.other_admin
        ],
        default_admin: default_admin
      })
    end

    defp save_platform(actor, kinds),
      do: Security.save_platform_alert_settings(%{disabled_kinds: kinds}, actor: actor)

    defp platform_notices,
      do: Enum.filter(SecurityAlerts.dispatches(), &(&1["channel"] == "platform_notice"))

    defp mails_sent(acc \\ []) do
      receive do
        {:email, mail} -> mails_sent([mail | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp platform_alerts_changed do
      # authorize?: false — reading the instance log back in a test.
      Security.list_instance_events!(authorize?: false)
      |> Enum.filter(&(&1.type == :platform_alerts_changed))
    end

    test "turning a kind off tells every platform admin, the actor and the muted included",
         ctx do
      assert {:ok, _row} = save_platform(ctx.platform, ["api_key_rate_limited"])

      assert [dispatch] = SecurityAlerts.dispatches()
      assert dispatch["channel"] == "platform_notice"
      assert dispatch["kind"] == "alerts_silenced"
      assert dispatch["org_id"] == ctx.default_org_id
      assert dispatch["scope"] == "platform_notice:" <> dispatch["id"]

      assert dispatch["notice"] == %{
               "change" => "platform_kind_disabled",
               "kinds" => ["api_key_rate_limited"],
               "actor_id" => ctx.platform.id
             }

      assert [_event] = platform_alerts_changed()

      SecurityAlerts.deliver()

      told = [ctx.platform, ctx.muted_platform, ctx.temporary_platform]
      bells = Notification |> Repo.all() |> Enum.filter(&(&1.event == :security_notice))

      assert MapSet.new(bells, & &1.user_id) == MapSet.new(told, & &1.id)
      assert Enum.all?(bells, &(&1.org_id == ctx.default_org_id))

      assert Enum.all?(
               bells,
               &(&1.content_type == Notifications.platform_alert_content_type())
             )

      assert Enum.all?(bells, &(&1.excerpt == "Some platform security alerts were turned off"))

      Oban.drain_queue(queue: :mail, with_recursion: true)
      mails = mails_sent()

      assert mails |> Enum.flat_map(& &1.to) |> Enum.map(&elem(&1, 1)) |> Enum.sort() ==
               told |> Enum.map(&to_string(&1.email)) |> Enum.sort()

      mail = hd(mails)
      assert mail.subject == "Platform security alerts were changed"
      assert mail.html_body =~ "Turned off: An API key hit a rate limit."
      assert mail.html_body =~ "/editor/security-alerts"

      assert mail.html_body =~
               "You get this because you are a platform administrator. Notices like this cannot be muted."

      # No webhook: a platform notice is not a webhook event.
      assert CMS.WebhookDelivery |> Repo.all() == []

      # Counted as a platform alert in another site's console, for a
      # platform admin only.
      assert Notifications.unread_platform_alert_count(ctx.platform, ctx.org) == 1
      assert Notifications.unread_platform_alert_count(ctx.default_admin, ctx.org) == 0

      assert [%{"alert_sent_at" => %{}}] = SecurityAlerts.dispatches()
    end

    test "nobody else hears it", ctx do
      {:ok, _row} = save_platform(ctx.platform, ["api_key_rate_limited"])
      SecurityAlerts.deliver()
      Oban.drain_queue(queue: :mail, with_recursion: true)

      heard = Notification |> Repo.all() |> MapSet.new(& &1.user_id)
      sent = mails_sent() |> Enum.flat_map(& &1.to) |> MapSet.new(&elem(&1, 1))

      for user <- ctx.refused do
        refute user.id in heard
        refute to_string(user.email) in sent
      end
    end

    test "turning it back on, saving it unchanged, or saving it off again says nothing", ctx do
      {:ok, _row} = save_platform(ctx.platform, ["api_key_rate_limited"])
      Repo.query!("DELETE FROM security_alert_dispatches")

      {:ok, _row} = save_platform(ctx.platform, ["api_key_rate_limited"])
      {:ok, _row} = save_platform(ctx.platform, [])
      {:ok, _row} = save_platform(ctx.platform, [])

      assert SecurityAlerts.dispatches() == []
    end

    test "a first save that turns nothing off says nothing", ctx do
      {:ok, _row} = save_platform(ctx.platform, [])
      assert SecurityAlerts.dispatches() == []
    end

    test "a refused save sends no notice", ctx do
      for actor <- [ctx.admin, ctx.default_admin, ctx.editor, nil] do
        assert {:error, %Ash.Error.Forbidden{}} = save_platform(actor, ["api_key_rate_limited"])
      end

      assert {:error, %Ash.Error.Invalid{}} = save_platform(ctx.platform, ["new_api_key"])

      assert SecurityAlerts.dispatches() == []
      assert platform_alerts_changed() == []
    end

    test "a save whose settings cannot be read first is refused, and sends nothing", ctx do
      assert_raise Ash.Error.Forbidden, fn ->
        Security.with_alerts_actor(nil, fn ->
          save_platform(ctx.platform, ["api_key_rate_limited"])
        end)
      end

      assert SecurityAlerts.dispatches() == []
      assert platform_alerts_changed() == []
    end

    test "names only the kinds this save turned off, not one a newer release left", ctx do
      Ash.Seed.seed!(Security.PlatformAlertSettings, %{disabled_kinds: ["future_kind"]})

      {:ok, _row} = save_platform(ctx.platform, ["future_kind", "api_key_rate_limited"])

      assert [%{"notice" => %{"kinds" => ["api_key_rate_limited"]}}] = platform_notices()
    end
  end
end
