defmodule KilnCMS.Security.DeliverAlertTest do
  @moduledoc """
  Delivering a security alert (#2245), end to end through the AshOban
  triggers: who gets the bell, the email and the webhook, what each one says,
  and that a delivery is idempotent and fails closed.

  `async: false`: alerts are turned on (`KilnCMS.Test.SecurityAlerts.enable/0`,
  an `Application.put_env`).
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Notifications.Notification
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.Security.Recorder
  alias KilnCMS.Test.SecurityAlerts

  @moduletag :capture_log

  @ip "203.0.113.77"

  setup do
    SecurityAlerts.enable()

    org = org("deliver-a")
    other = org("deliver-b")

    admin = member!(user(:viewer), org.id, :admin)
    muted = member!(user(:viewer, %{notify_on_security_alert: false}), org.id, :admin)
    editor = member!(user(:viewer), org.id, :editor)
    platform = user(:admin)
    other_admin = member!(user(:viewer), other.id, :admin)

    %{
      org: org,
      other: other,
      admin: admin,
      muted: muted,
      editor: editor,
      platform: platform,
      other_admin: other_admin
    }
  end

  defp uniq, do: System.unique_integer([:positive])

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.User,
      Map.merge(
        %{
          email: "deliver-#{role}-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
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

  defp lockout(org_id) do
    {:ok, event} =
      Recorder.record(:sign_in_locked,
        tenant: org_id,
        target_type: "user",
        target_id: Ecto.UUID.generate(),
        request: %{ip: @ip, user_agent: "Secret-Agent/1.0"}
      )

    event
  end

  defp endpoint!(org_id, events, admin) do
    CMS.create_webhook_endpoint!(
      %{url: "https://hooks.example.com/#{uniq()}", events: events},
      actor: admin,
      tenant: org_id
    )
  end

  defp site_name(org), do: KilnCMS.Branding.for_org(org).site_name

  defp bells, do: Repo.all(Notification)
  defp bell_users(event), do: bells() |> Enum.filter(&(&1.event == event)) |> ids_of(:user_id)
  defp ids(users), do: users |> Enum.map(& &1.id) |> MapSet.new()
  defp ids_of(rows, key), do: rows |> Enum.map(&Map.fetch!(&1, key)) |> MapSet.new()

  defp deliveries do
    # authorize?: false — reading the webhook ledger back in a test.
    CMS.WebhookDelivery |> Repo.all() |> Enum.filter(&String.starts_with?(&1.event, "security."))
  end

  # Delivers the mail queue only: the webhook jobs stay enqueued, unsent.
  defp mails do
    Oban.drain_queue(queue: :mail, with_recursion: true)
    collect([])
  end

  defp collect(acc) do
    receive do
      {:email, mail} -> collect([mail | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp recipients(mails), do: mails |> Enum.flat_map(& &1.to) |> Enum.map(&elem(&1, 1))

  describe "a silencing notice" do
    test "links to the alert settings, not the security log", ctx do
      KilnCMS.Security.AlertGate.insert_notice!(ctx.org.id, %{
        change: "kind_disabled",
        kinds: ["lockout"],
        actor_id: ctx.admin.id
      })

      SecurityAlerts.deliver()

      assert [mail | _] = mails()
      assert mail.html_body =~ "/editor/security-alerts"
      assert mail.html_body =~ "Open the security alerts settings"
      refute mail.html_body =~ "/editor/security-log"
    end
  end

  describe "a site alert" do
    test "reaches the site's member admins: bell for each, email for the unmuted", ctx do
      lockout(ctx.org.id)
      SecurityAlerts.deliver()

      assert bell_users(:security_alert) == ids([ctx.admin, ctx.muted])
      assert [bell | _] = bells()
      assert bell.org_id == ctx.org.id
      assert bell.content_type == "security_alert_dispatch"
      # Not a document: the bell links to the security log.
      assert KilnCMS.Notifications.Link.editor_path(bell) == "/editor/security-log"
      assert KilnCMS.Notifications.Link.editor_url(bell) =~ ~r{^https?://.+/editor/security-log$}
      assert bell.title == site_name(ctx.org)
      # The address masked to its network, never the user agent.
      assert bell.excerpt == "An account was locked out (from 203.0.113.0/24)"

      mails = mails()
      assert recipients(mails) == [to_string(ctx.admin.email)]
      [mail] = mails
      assert mail.subject == "Security alert on #{site_name(ctx.org)}: An account was locked out"
      assert mail.html_body =~ "203.0.113.0/24"
      refute mail.html_body =~ @ip
      refute mail.html_body =~ "Secret-Agent"

      assert [%{"alert_sent_at" => %{}}] = SecurityAlerts.dispatches()
    end

    test "goes by the instance relay, not the site's own", ctx do
      CMS.save_site_mail_relay!(%{host: "smtp.example.com", from_email: "news@site.example"},
        tenant: ctx.org.id,
        authorize?: false
      )

      lockout(ctx.org.id)
      SecurityAlerts.deliver()

      jobs = Oban.Job |> Repo.all() |> Enum.filter(&(&1.worker == "KilnCMS.Mail.DeliveryWorker"))
      assert [job] = jobs
      refute Map.has_key?(job.args, "org_id")
    end

    test "reaches no platform admin, no editor and no other site", ctx do
      lockout(ctx.org.id)
      SecurityAlerts.deliver()

      users = bell_users(:security_alert)
      refute ctx.platform.id in users
      refute ctx.editor.id in users
      refute ctx.other_admin.id in users

      sent = recipients(mails())

      for user <- [ctx.platform, ctx.editor, ctx.other_admin],
          do: refute(to_string(user.email) in sent)
    end

    test "a site with no member admins tells the platform admins instead (OC-1)", ctx do
      bare = org("deliver-bare")
      muted_platform = user(:admin, %{notify_on_security_alert: false})
      endpoint!(bare.id, ["security.lockout"], ctx.platform)

      lockout(bare.id)
      SecurityAlerts.deliver()

      bell_users = bell_users(:security_alert)
      assert ctx.platform.id in bell_users
      assert muted_platform.id in bell_users
      # The site's bell, not the default site's: it is the site's alert.
      assert Enum.all?(bells(), &(&1.org_id == bare.id))
      # Their email follows the site-alert mute, like a member admin's.
      to = recipients(mails())
      assert to_string(ctx.platform.email) in to
      refute to_string(muted_platform.email) in to
      # No member admin of another site hears about it.
      refute ctx.other_admin.id in bell_users
      assert [%{event: "security.lockout"}] = deliveries()
    end

    test "a site with no member admins sends its notices to the platform admins (OC-2)", ctx do
      bare = org("deliver-bare-notice")

      KilnCMS.Security.AlertGate.insert_notice!(bare.id, %{
        change: "kind_disabled",
        kinds: ["lockout"],
        actor_id: ctx.platform.id
      })

      SecurityAlerts.deliver()

      assert ctx.platform.id in bell_users(:security_notice)
      refute ctx.admin.id in bell_users(:security_notice)
    end

    test "a site with member admins never adds the platform admins", ctx do
      lockout(ctx.org.id)
      SecurityAlerts.deliver()

      refute ctx.platform.id in bell_users(:security_alert)
    end

    test "a kind the site turned off sends nothing, not even its summary", ctx do
      endpoint!(ctx.org.id, ["security.lockout"], ctx.admin)

      CMS.save_site_security_alerts!(%{disabled_kinds: ["lockout"]},
        actor: ctx.admin,
        tenant: ctx.org.id
      )

      lockout(ctx.org.id)
      lockout(ctx.org.id)
      [alert] = Enum.filter(SecurityAlerts.dispatches(), &(&1["kind"] == "lockout"))
      SecurityAlerts.deliver()

      SecurityAlerts.close_window(alert["id"])
      SecurityAlerts.backdate_events()
      SecurityAlerts.deliver()

      assert bell_users(:security_alert) == MapSet.new()
      assert deliveries() == []

      [alert] = Enum.filter(SecurityAlerts.dispatches(), &(&1["id"] == alert["id"]))
      assert alert["alert_sent_at"]
      assert alert["summary_sent_at"]
    end

    test "failed sign-ins are off until the site turns them on", ctx do
      # Charged and recorded as the recorder would at the threshold.
      record = fn ->
        {:ok, _} =
          Recorder.record(:sign_in_failed,
            tenant: ctx.org.id,
            request: %{ip: @ip},
            alert: {:threshold, 1, 10}
          )
      end

      record.()
      SecurityAlerts.deliver()
      assert bell_users(:security_alert) == MapSet.new()

      CMS.save_site_security_alerts!(%{disabled_kinds: []}, actor: ctx.admin, tenant: ctx.org.id)
      Repo.query!("DELETE FROM security_alert_dispatches")
      record.()
      SecurityAlerts.deliver()
      assert bell_users(:security_alert) == ids([ctx.admin, ctx.muted])
    end

    test "with admin notifications off, only the webhooks go", ctx do
      endpoint!(ctx.org.id, ["security.lockout"], ctx.admin)

      CMS.save_site_security_alerts!(%{notify_admins: false},
        actor: ctx.admin,
        tenant: ctx.org.id
      )

      lockout(ctx.org.id)
      SecurityAlerts.deliver()

      assert bell_users(:security_alert) == MapSet.new()
      assert [%{event: "security.lockout"}] = deliveries()
    end

    test "with full addresses opted in, the full address is shown", ctx do
      CMS.save_site_security_alerts!(%{include_full_ip: true},
        actor: ctx.admin,
        tenant: ctx.org.id
      )

      lockout(ctx.org.id)
      SecurityAlerts.deliver()

      assert Enum.all?(
               Enum.filter(bells(), &(&1.event == :security_alert)),
               &(&1.excerpt =~ @ip)
             )
    end
  end

  describe "webhooks" do
    test "go to the site's subscribed, active endpoints only, in the Kiln envelope", ctx do
      subscribed = endpoint!(ctx.org.id, ["security.lockout"], ctx.admin)
      endpoint!(ctx.org.id, ["security.new_admin", "page.published"], ctx.admin)
      endpoint!(ctx.other.id, ["security.lockout"], ctx.other_admin)

      off = endpoint!(ctx.org.id, ["security.lockout"], ctx.admin)
      CMS.update_webhook_endpoint!(off, %{active: false}, actor: ctx.admin, tenant: ctx.org.id)

      event = lockout(ctx.org.id)
      SecurityAlerts.deliver()

      assert [delivery] = deliveries()
      assert delivery.endpoint_id == subscribed.id
      assert delivery.org_id == ctx.org.id

      payload = delivery.payload
      assert payload["kind"] == "lockout"
      assert payload["phase"] == "alert"
      assert payload["channel"] == "site"
      assert payload["site_id"] == ctx.org.id
      assert payload["count"] == 1
      assert payload["event"]["id"] == event.id
      assert payload["event"]["ip"] == "203.0.113.0/24"
      assert payload["console_url"] =~ "/editor/security-log"

      encoded = Jason.encode!(payload)
      refute encoded =~ "Secret-Agent"
      refute encoded =~ "@example.com"
      refute encoded =~ "hooks.example.com"

      # Signed like any delivery: the worker's envelope and `verify/4`.
      job =
        Oban.Job
        |> Repo.all()
        |> Enum.find(&(&1.worker == "KilnCMS.Webhooks.DeliveryWorker"))

      assert job.args["delivery_id"] == delivery.id
    end

    test "a platform alert sends no webhook", ctx do
      endpoint!(Accounts.default_org_id(), ["security.new_admin"], ctx.platform)

      {:ok, _} =
        Accounts.manage_user_access(user(:editor), %{role: :admin},
          actor: ctx.platform,
          context: KilnCMS.Security.AuthEvents.context(Plug.Test.conn(:get, "/"), ctx.org.id)
        )

      SecurityAlerts.deliver()
      assert deliveries() == []
    end
  end

  describe "a platform alert" do
    test "every platform admin gets bell and email, muted or not, in the default org", ctx do
      muted_platform = user(:admin, %{notify_on_security_alert: false})

      {:ok, _} =
        Accounts.manage_user_access(user(:editor), %{role: :admin},
          actor: ctx.platform,
          context: KilnCMS.Security.AuthEvents.context(Plug.Test.conn(:get, "/"), ctx.org.id)
        )

      SecurityAlerts.deliver()

      users = bell_users(:security_alert)
      assert ctx.platform.id in users
      assert muted_platform.id in users
      refute ctx.admin.id in users

      assert Enum.all?(bells(), &(&1.org_id == Accounts.default_org_id()))

      sent = recipients(mails())
      assert to_string(muted_platform.email) in sent
      refute to_string(ctx.admin.email) in sent
    end
  end

  describe "delivery" do
    test "is idempotent: running the triggers again sends nothing more", ctx do
      lockout(ctx.org.id)
      SecurityAlerts.deliver()
      SecurityAlerts.deliver()

      [dispatch] = SecurityAlerts.dispatches()

      # Straight at the action, past the trigger's own "not yet sent" filter:
      # the stamp on the locked row is what stops a second delivery.
      # authorize?: false — the action is the triggers' alone (AshOban's bypass).
      assert {:ok, _} =
               Security.deliver_alert_dispatch(
                 struct(Security.AlertDispatch, %{
                   id: dispatch["id"],
                   channel: :site,
                   kind: "lockout",
                   org_id: ctx.org.id
                 }),
                 authorize?: false
               )

      assert length(bells()) == 2
    end

    test "fails closed: a refused endpoint read writes nothing and is retried", ctx do
      endpoint!(ctx.org.id, ["security.lockout"], ctx.admin)
      lockout(ctx.org.id)

      KilnCMS.Webhooks.with_actor(%{id: "nobody"}, fn -> SecurityAlerts.deliver() end)

      # Every attempt failed and rolled back; the last one stamped the row
      # failed, so the trigger stops picking it up.
      assert bells() == []
      assert deliveries() == []
      assert [%{"alert_sent_at" => nil, "failed_at" => %{}}] = SecurityAlerts.dispatches()

      # With the grant back (and the stamp cleared), it goes.
      Repo.query!("UPDATE security_alert_dispatches SET failed_at = NULL")
      SecurityAlerts.deliver()
      assert length(bells()) == 2
      assert [_] = deliveries()
    end

    test "unreadable settings deliver as the defaults: alerting, and masked", ctx do
      CMS.save_site_security_alerts!(%{include_full_ip: true},
        actor: ctx.admin,
        tenant: ctx.org.id
      )

      lockout(ctx.org.id)

      KilnCMS.OrgSettings.with_actor(%{id: "nobody"}, fn -> SecurityAlerts.deliver() end)

      excerpts = bells() |> Enum.map(& &1.excerpt)
      assert length(excerpts) == 2
      assert Enum.all?(excerpts, &(&1 =~ "203.0.113.0/24"))
    end

    test "a missing row is nothing to do", ctx do
      lockout(ctx.org.id)
      Repo.query!("DELETE FROM security_alert_dispatches")
      SecurityAlerts.deliver()
      assert bells() == []
    end
  end

  describe "summaries" do
    test "a window with more than its alert is summarized once it closes", ctx do
      lockout(ctx.org.id)
      lockout(ctx.org.id)
      lockout(ctx.org.id)
      SecurityAlerts.deliver()
      _alert_mails = mails()

      [dispatch] = SecurityAlerts.dispatches()
      SecurityAlerts.close_window(dispatch["id"])
      SecurityAlerts.backdate_events()
      SecurityAlerts.deliver()

      summaries = Enum.filter(bells(), &(&1.excerpt =~ "in this alert window"))
      assert length(summaries) == 2
      assert hd(summaries).excerpt == "An account was locked out: 3 in this alert window"

      assert [mail] = mails()
      assert mail.subject == "Security alert summary for #{site_name(ctx.org)}"

      [dispatch] = SecurityAlerts.dispatches()
      assert dispatch["summary_sent_at"]
    end

    test "a window with only its alert sends no summary, and is done", ctx do
      lockout(ctx.org.id)
      SecurityAlerts.deliver()

      [dispatch] = SecurityAlerts.dispatches()
      SecurityAlerts.close_window(dispatch["id"])
      SecurityAlerts.backdate_events()
      SecurityAlerts.deliver()

      assert length(bells()) == 2
      assert [%{"summary_sent_at" => %{}}] = SecurityAlerts.dispatches()
    end
  end
end
