defmodule KilnCMS.Security.NoticesTest do
  @moduledoc """
  `alerts_silenced` notices (#2245): turning a site's alerts quieter — in its
  alert settings, or on a webhook endpoint subscribed to security events —
  always tells the site's member admins, muted or not, and nobody else.

  `async: false`: alerts are turned on for the delivery
  (`KilnCMS.Test.SecurityAlerts.enable/0`, an `Application.put_env`).
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Notifications.Notification
  alias KilnCMS.Repo
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
end
