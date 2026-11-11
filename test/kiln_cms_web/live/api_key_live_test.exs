defmodule KilnCMSWeb.ApiKeyLiveTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User

  @password "password123456"

  defp authed_user(role) do
    email = "apikey-live-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  describe "authorization" do
    test "anonymous users are redirected to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/api-keys")
    end

    test "editors are redirected away", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))

      assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
               live(conn, ~p"/editor/api-keys")
    end

    test "admins can load the page", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/api-keys")
      assert html =~ "API keys"
      assert html =~ "Create a key"
    end
  end

  describe "mint + revoke" do
    test "admin mints a key and sees the plaintext once", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/api-keys")

      html =
        lv
        |> form("#new-api-key-form", %{name: "marketing-site", user_id: admin.id, days: "90"})
        |> render_submit()

      # The one-time plaintext banner shows a kiln_-prefixed key.
      assert html =~ "won&#39;t be shown again" or html =~ "won't be shown again"
      assert html =~ "kiln_"
      assert html =~ "marketing-site"
    end

    # #1771: the owner select used to render only user options, so the browser
    # silently picked whoever `list_users!` returned first — an admin could mint
    # a key acting as the wrong account without noticing.
    test "the owner defaults to the signed-in admin, not the first listed user",
         %{conn: conn} do
      # Seeded first so it would lead an insertion-ordered list, and with an
      # email that would lead an alphabetical one.
      other =
        Ash.Seed.seed!(User, %{
          email: "aaa-first-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })

      admin = authed_user(:admin)
      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/api-keys")

      # Exactly one owner option is selected, and it is the signed-in admin.
      doc = LazyHTML.from_fragment(html)
      selected = LazyHTML.query(doc, "#new-api-key-owner option[selected]")
      assert LazyHTML.attribute(selected, "value") == [admin.id]
      assert LazyHTML.text(selected) =~ "you"

      # The choice is still visible and explicit: the other user is offered.
      assert has_element?(lv, "#new-api-key-owner option[value='#{other.id}']")
      assert has_element?(lv, "#new-api-key-owner-hint")

      # Submitting without touching the select mints the key for the admin.
      lv
      |> form("#new-api-key-form", %{name: "default-owner", days: "30"})
      |> render_submit()

      [key] =
        KilnCMS.Accounts.list_all_api_keys!(actor: admin)
        |> Enum.filter(&(&1.name == "default-owner"))

      assert key.user_id == admin.id
    end

    test "minting for another user is an explicit choice that is honoured", %{conn: conn} do
      admin = authed_user(:admin)
      editor = authed_user(:editor)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/api-keys")

      lv
      |> form("#new-api-key-form", %{name: "for-editor", user_id: editor.id, days: "30"})
      |> render_submit()

      [key] =
        KilnCMS.Accounts.list_all_api_keys!(actor: admin)
        |> Enum.filter(&(&1.name == "for-editor"))

      assert key.user_id == editor.id
    end

    test "a blank owner is refused with a flash instead of crashing", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/api-keys")

      html = render_submit(lv, "mint", %{"user_id" => "", "name" => "x", "days" => "30"})
      assert html =~ "Choose which user the key acts as"
    end

    test "a drafts-only key can be minted with a self-rotation window", %{conn: conn} do
      admin = authed_user(:admin)
      service = authed_user(:viewer)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/api-keys")

      html =
        lv
        |> form("#new-api-key-form", %{
          name: "rotating",
          user_id: service.id,
          days: "30",
          access: "draft_write",
          rotate_days: "180"
        })
        |> render_submit()

      assert html =~ "Rotates itself until"

      [key] =
        Enum.filter(KilnCMS.Accounts.list_all_api_keys!(actor: admin), &(&1.name == "rotating"))

      assert DateTime.diff(key.rotatable_until, DateTime.utc_now(), :day) in 179..180
    end

    test "other scopes ignore the self-rotation field", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/api-keys")

      lv
      |> form("#new-api-key-form", %{
        name: "plain",
        user_id: admin.id,
        days: "30",
        access: "read",
        rotate_days: "180"
      })
      |> render_submit()

      [key] =
        Enum.filter(KilnCMS.Accounts.list_all_api_keys!(actor: admin), &(&1.name == "plain"))

      assert is_nil(key.rotatable_until)
    end

    test "a key retired by rotation reads Rotated and its successor names it", %{conn: conn} do
      admin = authed_user(:admin)
      service = authed_user(:viewer)

      key =
        KilnCMS.Accounts.mint_api_key!(
          service.id,
          "svc",
          DateTime.add(DateTime.utc_now(), 7, :day),
          %{access: :draft_write, rotatable_until: DateTime.add(DateTime.utc_now(), 90, :day)},
          actor: admin
        )

      {:ok, actor} =
        KilnCMS.Accounts.actor_from_api_key(Ash.Resource.get_metadata(key, :plaintext_api_key))

      {:ok, successor} = KilnCMS.Accounts.rotate_api_key(actor: actor)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/api-keys")

      assert lv |> element("#api-key-#{key.id}") |> render() =~ "Rotated"
      refute lv |> element("#api-key-#{key.id}") |> render() =~ "Revoke<"

      assert lv |> element("#api-key-#{successor.id}") |> render() =~
               "Rotated from #{String.slice(key.id, 0, 8)}"
    end

    test "admin revokes a key", %{conn: conn} do
      admin = authed_user(:admin)

      key =
        KilnCMS.Accounts.mint_api_key!(
          admin.id,
          "to-revoke",
          DateTime.add(DateTime.utc_now(), 30, :day),
          actor: admin
        )

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/api-keys")

      html =
        lv
        |> element("#api-key-#{key.id} button", "Revoke")
        |> render_click()

      assert html =~ "Revoked"

      reloaded = KilnCMS.Accounts.get_api_key!(key.id, actor: admin)
      assert reloaded.revoked_at
    end
  end

  describe "audit log (#2241)" do
    test "minting and revoking from the console records both, in this site's log", %{conn: conn} do
      admin = authed_user(:admin)
      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/api-keys")

      lv
      |> form("#new-api-key-form", %{name: "audited", user_id: admin.id, days: "30"})
      |> render_submit()

      org = KilnCMS.Accounts.default_org_id()
      list = fn -> KilnCMS.Security.list_events!(actor: admin, tenant: org) end

      assert [event] = Enum.filter(page(list.()), &(&1.type == :api_key_created))
      assert event.actor_id == admin.id
      assert event.org_id == org
      assert event.metadata == %{"name" => "audited", "scope" => "read"}

      key = hd(KilnCMS.Accounts.list_api_keys!(admin.id, actor: admin))
      render_click(lv, "revoke", %{"id" => key.id})

      assert [%{metadata: %{"name" => "audited"}}] =
               Enum.filter(page(list.()), &(&1.type == :api_key_revoked))
    end

    defp page(%{results: results}), do: results
    defp page(list) when is_list(list), do: list
  end
end
