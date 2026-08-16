defmodule KilnCMSWeb.FederationLiveTest do
  @moduledoc """
  `/editor/federation` (#967): the admin auth matrix, the two halves of the
  gate, enabling from the page (minting the identity), the editable profile,
  followers with block/remove, the block list, and the delivery ledger. Plus
  the replay-store sweeper, which has no other home.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Federation

  @password "password1234!"

  setup do
    previous = Application.get_env(:kiln_cms, KilnCMS.Federation, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Federation, previous) end)
    %{org_id: KilnCMS.Accounts.default_org_id()}
  end

  defp deployment!(enabled?) do
    current = Application.get_env(:kiln_cms, KilnCMS.Federation, [])
    Application.put_env(:kiln_cms, KilnCMS.Federation, Keyword.put(current, :enabled, enabled?))
  end

  defp authed_user(role) do
    email = "fedlive-#{role}-#{System.unique_integer([:positive])}@example.com"

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

  defp follower!(org_id, actor_uri) do
    Federation.follow!(actor_uri, actor_uri <> "/inbox", %{}, authorize?: false, tenant: org_id)
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/federation")
    end

    test "turns away a non-admin", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               conn |> log_in(authed_user(:editor)) |> live(~p"/editor/federation")

      assert flash["error"] =~ "admin access"
    end
  end

  describe "the gate and the identity" do
    test "shows both halves — deployment off, site never enabled", %{conn: conn} do
      deployment!(false)
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/federation")

      assert has_element?(lv, "#deployment-gate", "disabled")
      assert has_element?(lv, "#site-gate", "never enabled")
      refute has_element?(lv, "#handle")
      assert has_element?(lv, "button", "Enable federation")
    end

    test "enabling from the page mints the identity with the picked username; disabling keeps it",
         %{conn: conn, org_id: org_id} do
      deployment!(true)
      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor/federation")

      html =
        lv
        |> form("form[phx-submit=enable]", %{
          "username" => "newsroom",
          "origin" => "https://news.example"
        })
        |> render_submit()

      assert html =~ "handle is now permanent"
      assert has_element?(lv, "#handle", "@newsroom@news.example")
      assert has_element?(lv, "#site-gate", "enabled")

      [settings] = Federation.list_site_federation!(authorize?: false, tenant: org_id)
      assert settings.enabled and settings.username == "newsroom"
      assert is_binary(settings.public_key_pem)

      html = lv |> element("button", "Disable federation") |> render_click()
      assert html =~ "identity is kept"
      assert has_element?(lv, "#site-gate", "disabled (identity kept)")
      # Still shown — the handle survives a disable.
      assert has_element?(lv, "#handle", "@newsroom@news.example")

      [settings] = Federation.list_site_federation!(authorize?: false, tenant: org_id)
      refute settings.enabled
      assert settings.username == "newsroom"
    end
  end

  describe "an enabled site" do
    setup %{conn: conn, org_id: org_id} do
      deployment!(true)
      admin = authed_user(:admin)

      Federation.enable_site_federation!("https://site.example", "kiln",
        authorize?: false,
        tenant: org_id
      )

      %{conn: log_in(conn, admin), admin: admin}
    end

    test "the profile is editable through :save", %{conn: conn, org_id: org_id} do
      {:ok, lv, _html} = live(conn, ~p"/editor/federation")

      html =
        lv
        |> form("#profile-form",
          profile: %{display_name: "The Newsroom", summary: "All the news"}
        )
        |> render_submit()

      assert html =~ "Profile saved."
      [settings] = Federation.list_site_federation!(authorize?: false, tenant: org_id)
      assert settings.display_name == "The Newsroom"
      assert settings.summary == "All the news"
      # The identity was not touched.
      assert settings.username == "kiln"
    end

    test "followers are listed with their delivery health; block actor / block instance / remove",
         %{
           conn: conn,
           org_id: org_id
         } do
      a = follower!(org_id, "https://alpha.example/users/a")
      b = follower!(org_id, "https://alpha.example/users/b")
      c = follower!(org_id, "https://gamma.example/users/c")

      {:ok, lv, html} = live(conn, ~p"/editor/federation")
      assert html =~ "Followers</h2>" or html =~ "Followers"
      assert has_element?(lv, "#follower-#{a.id}")
      assert has_element?(lv, "#follower-#{b.id}")
      assert has_element?(lv, "#follower-#{c.id}")

      # Block one actor: its row goes, a block row appears, the others stay.
      lv |> element("#follower-#{c.id} button", "Block actor") |> render_click()
      refute has_element?(lv, "#follower-#{c.id}")
      assert has_element?(lv, "#blocks-list", "https://gamma.example/users/c")

      # Block a whole instance from a follower row: every follower on it goes.
      lv |> element("#follower-#{a.id} button", "Block instance") |> render_click()
      refute has_element?(lv, "#follower-#{a.id}")
      refute has_element?(lv, "#follower-#{b.id}")
      assert has_element?(lv, "#blocks-list", "alpha.example")

      assert [] == Federation.list_followers!(authorize?: false, tenant: org_id)
      assert length(Federation.list_blocks!(authorize?: false, tenant: org_id)) == 2

      # And a fresh follow from the blocked instance is refused at the inbox.
      assert Federation.blocked?("https://alpha.example/users/z", org_id)
      refute Federation.blocked?("https://delta.example/users/z", org_id)
    end

    test "the block form adds an instance (normalized) and unblock removes it", %{
      conn: conn,
      org_id: org_id
    } do
      {:ok, lv, _html} = live(conn, ~p"/editor/federation")

      lv
      |> form("form[phx-submit=block]", %{
        "kind" => "instance",
        "value" => " Spam.Example ",
        "reason" => "spam"
      })
      |> render_submit()

      assert [%{kind: :instance, value: "spam.example", reason: "spam"} = block] =
               Federation.list_blocks!(authorize?: false, tenant: org_id)

      assert has_element?(lv, "#block-#{block.id}", "spam.example")

      lv |> element("#block-#{block.id} button", "Unblock") |> render_click()
      assert [] == Federation.list_blocks!(authorize?: false, tenant: org_id)
      refute Federation.blocked?("https://spam.example/users/x", org_id)
    end

    test "the delivery ledger shows recent deliveries with their state", %{
      conn: conn,
      org_id: org_id
    } do
      f = follower!(org_id, "https://ledger.example/users/l")

      {:ok, delivery} =
        Federation.create_federation_delivery(
          %{
            follower_id: f.id,
            inbox_uri: f.inbox_uri,
            activity_type: :create,
            activity: %{"type" => "Create"},
            document_id: Ash.UUID.generate()
          },
          authorize?: false,
          tenant: org_id
        )

      {:ok, lv, _html} = live(conn, ~p"/editor/federation")
      assert has_element?(lv, "#delivery-#{delivery.id}", "https://ledger.example/users/l/inbox")
      assert has_element?(lv, "#delivery-#{delivery.id} .badge", "Pending")
    end

    test "a follower past the drop ceiling is marked, and the deliverable count says so", %{
      conn: conn,
      org_id: org_id
    } do
      live_one = follower!(org_id, "https://ok.example/users/o")
      dead = follower!(org_id, "https://dead.example/users/d")
      # Fold the record through: `increment` on a stale struct re-reads its
      # own starting value.
      Enum.reduce(1..Federation.drop_follower_after(), dead, fn _, follower ->
        Federation.record_follower_failure!(follower, authorize?: false, tenant: org_id)
      end)

      {:ok, lv, html} = live(conn, ~p"/editor/federation")
      assert has_element?(lv, "#follower-#{dead.id}", "dropped from delivery")
      refute has_element?(lv, "#follower-#{live_one.id}", "dropped from delivery")
      assert html =~ "1 will be delivered to"
    end
  end

  describe "the replay-store sweeper (#967)" do
    test "removes expired rows and leaves live ones" do
      alias KilnCMS.Federation.{SeenSignature, SeenSignatureSweeper}

      past = DateTime.add(DateTime.utc_now(), -10, :second)
      future = DateTime.add(DateTime.utc_now(), 600, :second)

      Federation.record_seen_signature!(
        %{signature_hash: String.duplicate("a", 64), expires_at: past},
        authorize?: false
      )

      Federation.record_seen_signature!(
        %{signature_hash: String.duplicate("b", 64), expires_at: future},
        authorize?: false
      )

      assert SeenSignatureSweeper.run() == 1
      assert [%{signature_hash: hash}] = Ash.read!(SeenSignature, authorize?: false)
      assert hash == String.duplicate("b", 64)
    end
  end
end
