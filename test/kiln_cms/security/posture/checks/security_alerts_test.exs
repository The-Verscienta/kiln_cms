defmodule KilnCMS.Security.Posture.Checks.SecurityAlertsTest do
  @moduledoc """
  `core.security_alerts_reach_someone` (#2640) against the site's real alert
  settings, admins and webhook endpoints: one test per row of the check's
  table, and settings or endpoints that cannot be read, which must be
  unknown rather than "nobody".

  `async: false`: alerts are off for the suite (`config/test.exs`), and
  `KilnCMS.Test.SecurityAlerts.enable/0` turns them on with
  `Application.put_env`.
  """
  use KilnCMS.DataCase, async: false

  # The unreadable cases log the refused read on purpose.
  @moduletag :capture_log

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.PostureFixtures

  alias KilnCMS.CMS
  alias KilnCMS.Security.Posture.Checks.SecurityAlerts
  alias KilnCMS.Test.SecurityAlerts, as: AlertsOn

  setup do
    %{site: org("pfalerts")}
  end

  defp run(site), do: SecurityAlerts.run(context(site))

  defp admin!(site, attrs \\ %{}), do: user(:viewer, attrs) |> member!(site, :admin)

  defp settings!(site, admin, attrs),
    do: CMS.save_site_security_alerts!(attrs, actor: admin, tenant: site.id)

  defp endpoint!(site, admin, events) do
    CMS.create_webhook_endpoint!(
      %{url: "https://hooks.example.com/#{System.unique_integer([:positive])}", events: events},
      actor: admin,
      tenant: site.id
    )
  end

  test "turned off for the whole deployment: warns, whatever the site set", %{site: site} do
    admin!(site)

    assert %{status: :warn, summary: summary, facts: facts, fix_path: nil} = run(site)
    assert summary == "Security alerts are turned off for this whole deployment."
    assert facts == %{deployment_enabled: false}
  end

  describe "with alerts on" do
    setup do
      AlertsOn.enable()
    end

    test "a member admin who gets the email: passes", %{site: site} do
      admin!(site)

      assert %{status: :pass, summary: summary, fix_path: nil, facts: facts} = run(site)
      assert summary == "Security alerts on this site reach its administrators."

      assert facts == %{
               deployment_enabled: true,
               enabled_kinds: length(KilnCMS.Security.Alerts.site_kinds()) - 1,
               notify_admins: true,
               member_admins: 1,
               fallback: false,
               bell_recipients: 1,
               email_recipients: 1,
               subscribed_endpoints: 0,
               uncovered_kinds: length(KilnCMS.Security.Alerts.site_kinds()) - 1
             }
    end

    test "every kind turned off: warns, and links to the alert settings", %{site: site} do
      admin = admin!(site)

      settings!(site, admin, %{
        disabled_kinds: Enum.map(KilnCMS.Security.Alerts.site_kinds(), &to_string/1)
      })

      assert %{status: :warn, summary: summary, fix_path: "/editor/security-alerts", facts: facts} =
               run(site)

      assert summary == "Every security alert is turned off on this site."
      assert facts.enabled_kinds == 0
    end

    test "bell and email off with no webhook: reaches nobody, fixed on the alert settings",
         %{site: site} do
      admin = admin!(site)
      settings!(site, admin, %{notify_admins: false})

      assert %{status: :warn, summary: summary, fix_path: "/editor/security-alerts"} = run(site)
      assert summary == "Security alerts on this site reach nobody."
    end

    test "no admins at all, not even platform admins: reaches nobody, fixed on Team",
         %{site: site} do
      assert KilnCMS.Accounts.Scoping.platform_admins() == []

      assert %{status: :warn, summary: summary, fix_path: "/editor/team", facts: facts} =
               run(site)

      assert summary == "Security alerts on this site reach nobody."
      assert %{member_admins: 0, bell_recipients: 0, fallback: false} = facts
    end

    test "no admins of its own: passes, going to the platform admins, and names none of them",
         %{site: site} do
      operator = user(:admin)

      assert %{status: :pass, summary: summary, fix_path: "/editor/team", facts: facts} =
               result = run(site)

      assert summary ==
               "Security alerts on this site go to the platform admins: this site has no admins of its own."

      assert %{member_admins: 0, fallback: true, bell_recipients: 1, email_recipients: 1} = facts
      assert result.details == []
      refute inspect(result) =~ to_string(operator.email)
      refute inspect(result) =~ operator.id
    end

    test "every admin muted the email: passes, by bell only", %{site: site} do
      admin!(site, %{notify_on_security_alert: false})
      admin!(site, %{notify_on_security_alert: false})

      assert %{status: :pass, summary: summary, fix_path: "/editor/settings", facts: facts} =
               run(site)

      assert summary ==
               "Security alerts on this site reach its administrators by bell only: each of them muted the email."

      assert %{bell_recipients: 2, email_recipients: 0} = facts
    end

    test "bell and email off but webhooks carry every kind on: passes, by webhook only",
         %{site: site} do
      admin = admin!(site)
      settings!(site, admin, %{notify_admins: false, disabled_kinds: []})
      [first | rest] = Enum.map(KilnCMS.Security.Alerts.site_kinds(), &"security.#{&1}")
      endpoint!(site, admin, [first])
      endpoint!(site, admin, rest)

      assert %{status: :pass, summary: summary, fix_path: "/editor/security-alerts", facts: facts} =
               run(site)

      assert summary == "Security alerts on this site go out only by webhook."

      assert %{subscribed_endpoints: 2, uncovered_kinds: 0, notify_admins: false} = facts
      assert facts.bell_recipients == 0
    end

    # A webhook for one kind is not a webhook for the others: with no bell or
    # email, a kind on that no endpoint carries reaches nobody.
    test "bell and email off, a webhook for some kinds only: warns, counting the rest",
         %{site: site} do
      admin = admin!(site)
      settings!(site, admin, %{notify_admins: false, disabled_kinds: []})
      endpoint!(site, admin, ["security.lockout", "security.new_admin"])

      assert %{status: :warn, summary: summary, fix_path: "/editor/security-alerts", facts: facts} =
               run(site)

      assert summary ==
               "Some security alerts on this site reach nobody: no webhook carries them, and no administrator gets them."

      kinds = length(KilnCMS.Security.Alerts.site_kinds())
      assert %{subscribed_endpoints: 1, enabled_kinds: ^kinds} = facts
      assert facts.uncovered_kinds == kinds - 2
    end

    test "blocked_ip, on by default, is uncovered by an endpoint made before it existed",
         %{site: site} do
      admin = admin!(site)
      settings!(site, admin, %{notify_admins: false})

      endpoint!(
        site,
        admin,
        Enum.map(KilnCMS.Security.Alerts.site_kinds() -- [:blocked_ip], &"security.#{&1}")
      )

      assert %{status: :warn, facts: %{uncovered_kinds: 1}} = run(site)
    end

    test "a webhook for some kinds only, with admins who get them: passes", %{site: site} do
      admin = admin!(site)
      endpoint!(site, admin, ["security.lockout"])

      assert %{status: :pass, summary: "Security alerts on this site reach its administrators."} =
               result = run(site)

      assert result.facts.uncovered_kinds > 0
    end

    test "a webhook subscribed only to a kind the site has off carries nothing", %{site: site} do
      admin = admin!(site)
      settings!(site, admin, %{notify_admins: false, disabled_kinds: ["failed_sign_ins"]})
      endpoint!(site, admin, ["security.failed_sign_ins", "page.published"])

      assert %{status: :warn, summary: "Security alerts on this site reach nobody.", facts: facts} =
               run(site)

      assert facts.subscribed_endpoints == 0
    end

    test "settings that cannot be read are unknown, not nobody", %{site: site} do
      admin = admin!(site)
      settings!(site, admin, %{notify_admins: false})

      result = KilnCMS.OrgSettings.with_actor(nil, fn -> run(site) end)

      assert %{status: :unknown, summary: "The site's security alert settings could not be read."} =
               result
    end

    test "endpoints that cannot be read are unknown, not none", %{site: site} do
      admin = admin!(site)
      settings!(site, admin, %{notify_admins: false})
      endpoint!(site, admin, ["security.lockout"])

      result = KilnCMS.Webhooks.with_actor(%{id: "nobody"}, fn -> run(site) end)

      assert %{status: :unknown, summary: "The site's webhook endpoints could not be read."} =
               result
    end

    test "the facts are scalars, at most twenty", %{site: site} do
      admin!(site)
      %{facts: facts} = run(site)

      assert map_size(facts) <= 20
      assert Enum.all?(Map.values(facts), &(is_integer(&1) or is_boolean(&1)))
    end
  end

  test "is a core site check, after core.idle_timeout" do
    assert SecurityAlerts.id() == "core.security_alerts_reach_someone"
    assert SecurityAlerts.scope() == :site
    assert Kiln.Security.Check.conformance(SecurityAlerts) == :ok

    core = KilnCMS.Security.Posture.Registry.core()
    index = Enum.find_index(core, &(&1 == SecurityAlerts))
    assert Enum.at(core, index - 1) == KilnCMS.Security.Posture.Checks.IdleTimeout
  end

  test "the title follows the reader's locale" do
    assert Gettext.with_locale(KilnCMSWeb.Gettext, "es", &SecurityAlerts.title/0) ==
             "Las alertas de seguridad llegan a alguien"

    assert Gettext.with_locale(KilnCMSWeb.Gettext, "fr", &SecurityAlerts.title/0) ==
             "Les alertes de sécurité atteignent quelqu'un"
  end
end
