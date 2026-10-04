defmodule KilnCMSWeb.SecurityTxtLiveTest do
  @moduledoc """
  `/editor/security-txt` (#1873): the admin gate, saving the form into the
  served file, the refusal of a forged line, and the expiry warning.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password1234!"

  setup do
    org = org("sectxtlive")
    on_exit(fn -> KilnCMS.Cache.bust_security_txt(org.id) end)
    %{org: org}
  end

  test "turns away a non-admin", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in(authed_user(:editor)) |> live(~p"/editor/security-txt")
  end

  test "says the site publishes no file until a contact is set", %{conn: conn, org: org} do
    {:ok, _lv, html} = admin_live(conn, org)
    assert html =~ "does not publish a security.txt"
    refute html =~ "security-txt-preview"
  end

  test "saves the form, and the page shows the file as served", %{conn: conn, org: org} do
    {:ok, lv, _html} = admin_live(conn, org)
    expires = Date.add(Date.utc_today(), 120)

    html =
      lv
      |> form("#security-txt-form",
        security_txt: %{
          "contacts" => "mailto:security@example.com\r\nhttps://example.com/report",
          "expires_on" => Date.to_iso8601(expires),
          "policy_url" => "https://example.com/security",
          "preferred_languages" => "en, fr",
          "encryption_url" => "",
          "acknowledgments_url" => ""
        }
      )
      |> render_submit()

    assert html =~ "security.txt saved."
    assert html =~ "Contact: https://example.com/report"
    assert html =~ "Expires: #{Date.to_iso8601(expires)}T23:59:59Z"

    assert {:ok, [row]} = CMS.list_site_security_txt(tenant: org, authorize?: false)
    assert row.contacts == ["mailto:security@example.com", "https://example.com/report"]
    assert row.preferred_languages == ["en", "fr"]
    assert row.encryption_url == nil

    body = build_conn() |> org_conn(org) |> get(~p"/.well-known/security.txt") |> response(200)
    assert body =~ "Policy: https://example.com/security"
  end

  test "a line break in a URL field is refused, and nothing is saved", %{conn: conn, org: org} do
    {:ok, lv, _html} = admin_live(conn, org)

    html =
      lv
      |> form("#security-txt-form",
        security_txt: %{
          "contacts" => "mailto:security@example.com",
          "expires_on" => Date.to_iso8601(Date.add(Date.utc_today(), 60)),
          "policy_url" => "https://example.com/p\nContact: mailto:evil@example.test"
        }
      )
      |> render_submit()

    assert html =~ "must be one line"
    assert {:ok, []} = CMS.list_site_security_txt(tenant: org, authorize?: false)
  end

  test "warns when the file expires within 30 days", %{conn: conn, org: org} do
    CMS.save_site_security_txt!(
      %{contacts: ["mailto:s@example.com"], expires_on: Date.add(Date.utc_today(), 10)},
      authorize?: false,
      tenant: org.id
    )

    {:ok, _lv, html} = admin_live(conn, org)
    assert html =~ "expires within 30 days"
  end

  test "warns when a stored date has passed", %{conn: conn, org: org} do
    # Seeded: the validation refuses a past date, but a saved one lapses.
    Ash.Seed.seed!(
      KilnCMS.CMS.SiteSecurityTxt,
      %{contacts: ["mailto:s@example.com"], expires_on: Date.add(Date.utc_today(), -3)},
      tenant: org.id
    )

    {:ok, _lv, html} = admin_live(conn, org)
    assert html =~ "This security.txt has expired."
  end

  test "remove drops the row, and the file 404s", %{conn: conn, org: org} do
    CMS.save_site_security_txt!(
      %{contacts: ["mailto:s@example.com"], expires_on: Date.add(Date.utc_today(), 90)},
      authorize?: false,
      tenant: org.id
    )

    {:ok, lv, _html} = admin_live(conn, org)
    html = lv |> element("button", "Remove security.txt") |> render_click()

    assert html =~ "no longer serves one"
    assert {:ok, []} = CMS.list_site_security_txt(tenant: org, authorize?: false)
    assert build_conn() |> org_conn(org) |> get(~p"/.well-known/security.txt") |> response(404)
  end

  defp admin_live(conn, org) do
    conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/security-txt")
  end

  defp authed_user(role) do
    email = "sectxtlive-#{role}-#{System.unique_integer([:positive])}@example.com"

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
