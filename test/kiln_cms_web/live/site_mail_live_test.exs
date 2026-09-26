defmodule KilnCMSWeb.SiteMailLiveTest do
  @moduledoc """
  The console screen behind `/editor/site-mail` (#1322): a site's own SMTP
  relay and From address.

  `KilnCMS.Mail.SiteRelayTest` covers the row and the resolver. This covers
  what only the screen does:

    * **the auth matrix** — a site admin is admitted on their own site, an
      editor is turned away, and a site sees only its own row;
    * **the write-only password** — never rendered, a blank save keeps it;
    * **the honest status line** — whose relay this site's mail is using, and
      the banner when the stored password can't be read;
    * **the test send** — through the saved relay, to the signed-in admin only.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Keys.Vault

  @password "password1234!"

  @valid %{
    "enabled" => "true",
    "host" => "smtp.example.com",
    "port" => "587",
    "security" => "starttls",
    "username" => "apikey",
    "password" => "s3cret-pass",
    "from_email" => "news@site.example",
    "from_name" => ""
  }

  setup do
    %{org: seed_org()}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/site-mail")
    end

    test "turns away an editor of this very site", %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :editor)

      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/site-mail")
    end

    test "admits a site admin on their own site, and their save lands there",
         %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :admin)

      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/site-mail")
      save(lv, @valid)

      assert %{host: "smtp.example.com"} = row!(org)
    end

    test "a site sees only its own relay", %{conn: conn, org: org} do
      other = seed_org()

      CMS.save_site_mail_relay!(
        %{host: "smtp.other.example", from_email: "a@other.example"},
        tenant: other,
        authorize?: false
      )

      html = conn |> mount_as_admin(org) |> render()

      refute html =~ "smtp.other.example"
      assert html =~ "the deployment&#39;s relay"
    end
  end

  describe "saving" do
    test "stores the password encrypted and never renders it", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      html = save(lv, @valid)

      assert html =~ "Outgoing mail saved."
      assert html =~ "goes out through smtp.example.com, from news@site.example"
      refute html =~ "s3cret-pass"
      assert html =~ "Saved. Leave blank to keep it."

      assert {:ok, "s3cret-pass"} = Vault.decrypt(row!(org).password_encrypted)
    end

    test "a later save with a blank password keeps the stored one", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, @valid)
      save(lv, %{@valid | "password" => "", "port" => "2525"})

      row = row!(org)
      assert row.port == 2525
      assert {:ok, "s3cret-pass"} = Vault.decrypt(row.password_encrypted)
    end

    test "an unchecked box switches it off and the status says so", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, @valid)
      html = save(lv, %{@valid | "enabled" => "false"})

      refute row!(org).enabled
      assert html =~ "the deployment&#39;s relay"
    end

    test "a private host is refused, with the reason", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      html = save(lv, %{@valid | "host" => "10.0.0.5"})

      assert html =~ "private or link-local"
      assert {:ok, []} = CMS.list_site_mail_relay(tenant: org, authorize?: false)
    end

    test "Remove puts the site back on the deployment's relay", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, @valid)

      lv |> element("button", "Remove") |> render_click()

      assert {:ok, []} = CMS.list_site_mail_relay(tenant: org, authorize?: false)
    end
  end

  describe "an unreadable password" do
    test "is called out, because the site's mail is being held", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, @valid)

      # What a SECRET_KEY_BASE rotation leaves behind.
      {1, _} =
        KilnCMS.Repo.update_all(
          from(r in "site_mail_relays", where: r.org_id == type(^org.id, :binary_id)),
          set: [password_encrypted: :crypto.strong_rand_bytes(48)]
        )

      html = conn |> mount_as_admin(org) |> render()
      assert html =~ "The saved password can&#39;t be read. Re-enter it."
    end
  end

  describe "sending a test" do
    test "goes through the saved relay, to the signed-in admin", %{conn: conn, org: org} do
      admin = authed_user(:admin)

      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(admin) |> live(~p"/editor/site-mail")
      save(lv, @valid)

      lv |> element("#site-mail-send-test") |> render_click()

      assert_receive {:site_relay_email, email, config}, 2_000
      assert email.to == [{"", to_string(admin.email)}]

      assert email.from ==
               {Map.fetch!(KilnCMS.Branding.for_org(org.id), :site_name), "news@site.example"}

      assert config[:relay] == "smtp.example.com"

      assert render_async(lv) =~ "Sent to #{admin.email}"
    end

    test "is not offered while the relay is switched off", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      save(lv, %{@valid | "enabled" => "false"})

      refute has_element?(lv, "#site-mail-send-test")
    end
  end

  describe "delivery health" do
    test "lists this site's suppressed addresses only, and Remove clears one",
         %{conn: conn, org: org} do
      other = seed_org()
      suppress!(org, "dead@reader.example")
      suppress!(other, "elsewhere@reader.example")

      # The operator's instance-wide list isn't this page's to show or clear.
      KilnCMS.Mail.suppress_recipient!(%{email: "operator@reader.example"}, authorize?: false)

      lv = mount_as_admin(conn, org)
      html = render(lv)

      assert html =~ "dead@reader.example"
      refute html =~ "elsewhere@reader.example"
      refute html =~ "operator@reader.example"

      [entry] = KilnCMS.Mail.list_site_suppressed_recipients!(tenant: org, authorize?: false)
      lv |> element("#site-suppressed-#{entry.id} button", "Remove") |> render_click()

      refute render(lv) =~ "dead@reader.example"
      refute KilnCMS.Mail.suppressed?("dead@reader.example", org_id: org.id)
      assert KilnCMS.Mail.suppressed?("elsewhere@reader.example", org_id: other.id)
    end

    test "a forged Remove for another site's entry clears nothing", %{conn: conn, org: org} do
      other = seed_org()
      theirs = suppress!(other, "elsewhere@reader.example")

      lv = mount_as_admin(conn, org)
      assert render_click(lv, "unsuppress", %{"id" => theirs.id}) =~ "Couldn&#39;t remove"

      assert KilnCMS.Mail.suppressed?("elsewhere@reader.example", org_id: other.id)
    end

    test "shows this site's recent bounces by domain", %{conn: conn, org: org} do
      KilnCMS.Repo.insert!(%Oban.Job{
        worker: "KilnCMS.Mail.DeliveryWorker",
        queue: "mail",
        state: "cancelled",
        args: %{"to" => ["", "gone@bounced-site.example"], "org_id" => org.id},
        errors: [%{"error" => "{:cancel, \"permanent delivery failure: 550 5.1.1\"}"}],
        attempted_at: DateTime.utc_now()
      })

      html = conn |> mount_as_admin(org) |> element("#site-mail-failures") |> render()

      assert html =~ "bounced-site.example"
      refute html =~ "gone@"
    end
  end

  defp suppress!(org, address) do
    KilnCMS.Mail.suppress_site_recipient!(%{email: address, reason: "550 5.1.1"},
      tenant: org,
      authorize?: false
    )
  end

  defp mount_as_admin(conn, org) do
    {:ok, lv, _html} =
      conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/site-mail")

    lv
  end

  defp save(lv, params) do
    lv |> form("#site-mail-form", relay: params) |> render_submit()
  end

  defp row!(org) do
    {:ok, [row]} = CMS.list_site_mail_relay(tenant: org, authorize?: false)
    row
  end

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Mail Site",
      slug: "sitemail-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp grant_tier(user, org, tier) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp authed_user(role) do
    email = "sitemail-#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
