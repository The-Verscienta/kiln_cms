defmodule KilnCMS.Mail.SiteRelayIsolationTest do
  @moduledoc """
  A site's relay connection carries nothing from the operator's mailer config
  (#1322, `KilnCMS.Mail.SiteRelay`'s moduledoc).

  `KilnCMS.Mailer.deliver/2` merges the config it is given over the app's, so a
  site relay delivered through it would inherit whatever key the site's config
  happens not to set — the operator's relay password, one missing key away from
  being sent to a host a tenant chose. In the test env the operator's config is
  only `adapter: Swoosh.Adapters.Test`, which the site config overrides anyway,
  so without planting real operator credentials nothing would notice the merge.

  `async: false` because it rewrites the global mailer config.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Mail

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Mailer)

    Application.put_env(:kiln_cms, KilnCMS.Mailer,
      adapter: Swoosh.Adapters.Test,
      relay: "operator-relay.example",
      username: "operator",
      password: "operator-password",
      dkim: [s: "operator", d: "operator.example", private_key: {:pem_plain, "x"}]
    )

    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Mailer, original) end)

    org = KilnCMS.OrgFixtures.org("relay-isolation")

    CMS.save_site_mail_relay!(
      %{host: "smtp.example.com", from_email: "news@site.example"},
      tenant: org,
      authorize?: false
    )

    %{org: org}
  end

  test "no operator key reaches a site's connection", %{org: org} do
    email =
      Swoosh.Email.new(
        from: {"KilnCMS", "cms@operator.example"},
        to: "reader@example.com",
        subject: "Hi",
        text_body: "Hi"
      )

    assert :ok = Mail.deliver_for_worker(email, org_id: org.id)

    assert_received {:site_relay_email, _email, config}
    assert config[:relay] == "smtp.example.com"
    refute Keyword.has_key?(config, :username)
    refute Keyword.has_key?(config, :password)
    refute Keyword.has_key?(config, :dkim)
  end
end
