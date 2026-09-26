defmodule KilnCMSWeb.SitePushLiveTest do
  @moduledoc """
  The console screen behind `/editor/site-push` (#1560): a site's own Web Push
  key pair.

  `KilnCMS.Push.KeysTest` covers the row, the resolver and the subscription
  binding. This covers what only the screen does:

    * **the auth matrix** — a site admin is admitted on their own site, an
      editor is turned away, and a site sees only its own key;
    * **Generate** — no key field anywhere, the private half never rendered;
    * **the honest status line** — whose key new devices subscribe with;
    * **rotation** — confirmed with the count of devices it cuts off;
    * **the unreadable-key banner**.
  """
  # async: false — configures the global deployment VAPID keys.
  use KilnCMSWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Keys.Vault
  alias KilnCMS.Push
  alias KilnCMS.Push.Vapid

  @password "password1234!"

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Push, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Push, original) end)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Push,
      Keyword.drop(original, [:vapid_public_key, :vapid_private_key, :vapid_subject])
    )

    %{org: KilnCMS.OrgFixtures.org("sitepush"), original: original}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/site-push")
    end

    test "turns away an editor of this very site", %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :editor)

      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/site-push")
    end

    test "admits a site admin on their own site, and their key lands there",
         %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :admin)

      {:ok, lv, _html} = conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/site-push")
      lv |> element("#site-push-generate") |> render_click()

      assert %{public_key: key, subject: subject} = row!(org)
      assert is_binary(key)
      assert subject == "mailto:#{user.email}"
    end

    test "a site sees only its own key", %{conn: conn, org: org} do
      other = KilnCMS.OrgFixtures.org("sitepush-other")
      other_row = CMS.generate_site_vapid_key!(%{}, tenant: other, authorize?: false)

      html = conn |> mount_as_admin(org) |> render()

      refute html =~ other_row.public_key
      assert html =~ "it has no key yet"
    end
  end

  describe "generating" do
    test "shows the public key and never the private one", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      html = lv |> element("#site-push-generate") |> render_click()

      row = row!(org)
      {:ok, private} = Vault.decrypt(row.private_key_encrypted)

      assert html =~ "Key generated."
      assert html =~ row.public_key
      refute html =~ private
      assert html =~ "subscribe with this site&#39;s own key"
      refute has_element?(lv, "#site-push-generate")
    end

    test "says so when the site is on the deployment's key", %{conn: conn, org: org} = ctx do
      {public, private} = Vapid.generate()

      Application.put_env(
        :kiln_cms,
        KilnCMS.Push,
        Keyword.merge(ctx.original, vapid_public_key: public, vapid_private_key: private)
      )

      html = conn |> mount_as_admin(org) |> render()
      assert html =~ "uses the deployment&#39;s push key"
    end

    test "the contact can be edited", %{conn: conn, org: org} do
      lv = mount_as_admin(conn, org)
      lv |> element("#site-push-generate") |> render_click()

      lv
      |> form("#site-push-subject-form", push: %{subject: "https://example.com/contact"})
      |> render_submit()

      assert row!(org).subject == "https://example.com/contact"
    end
  end

  describe "rotating" do
    test "the confirmation names how many devices it cuts off, and the rotation drops them",
         %{conn: conn, org: org} do
      row = CMS.generate_site_vapid_key!(%{}, tenant: org, authorize?: false)
      subscription = subscribe!(org)

      lv = mount_as_admin(conn, org)

      assert lv |> element("#site-push-rotate") |> render() =~
               "1 device stops receiving notifications"

      html = lv |> element("#site-push-rotate") |> render_click()

      assert html =~ "Key rotated."
      refute row!(org).public_key == row.public_key

      assert {:ok, nil} =
               Accounts.get_push_subscription(subscription.id,
                 authorize?: false,
                 not_found_error?: false
               )
    end
  end

  describe "an unreadable private key" do
    test "is called out, because the site's pushes are held", %{conn: conn, org: org} do
      row = CMS.generate_site_vapid_key!(%{}, tenant: org, authorize?: false)

      {1, _} =
        KilnCMS.Repo.update_all(
          from(r in "site_vapid_keys", where: r.id == type(^row.id, :binary_id)),
          set: [private_key_encrypted: :crypto.strong_rand_bytes(64)]
        )

      html = conn |> mount_as_admin(org) |> render()
      assert html =~ "can&#39;t be read. Rotate it."
    end
  end

  defp subscribe!(org) do
    {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)

    {:ok, subscription} =
      Push.subscribe(
        %{
          "endpoint" => "https://push.example.com/x/#{System.unique_integer([:positive])}",
          "p256dh" => Base.url_encode64(public, padding: false),
          "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        },
        authed_user(:editor),
        org
      )

    subscription
  end

  defp mount_as_admin(conn, org) do
    {:ok, lv, _html} =
      conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/site-push")

    lv
  end

  defp row!(org) do
    {:ok, [row]} = CMS.list_site_vapid_key(tenant: org, authorize?: false)
    row
  end

  defp grant_tier(user, org, tier) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp authed_user(role) do
    email = "sitepush-#{role}-#{System.unique_integer([:positive])}@example.com"

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
