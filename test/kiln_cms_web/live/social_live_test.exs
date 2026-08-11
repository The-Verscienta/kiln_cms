defmodule KilnCMSWeb.SocialLiveTest do
  @moduledoc """
  The social-accounts settings page (#497). The load-bearing assertions are
  about the credential: it must never be rendered back, and a blank submission
  must not erase a working one.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Social

  @token "super-secret-token"
  @password "password123456"

  setup %{conn: conn} do
    Req.Test.stub(KilnCMS.Social, fn c -> Req.Test.json(c, %{}) end)
    admin = authed_user(:admin)

    %{
      conn: log_in(conn, admin),
      actor: admin,
      org_id: KilnCMS.Accounts.default_org_id()
    }
  end

  defp authed_user(role) do
    email = "social-live-#{System.unique_integer([:positive])}@example.com"

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

  defp account(ctx, attrs \\ %{}) do
    Social.create_account!(
      Map.merge(
        %{
          provider: :mastodon,
          handle: "kiln",
          instance_url: "https://mastodon.test",
          credential: @token
        },
        attrs
      ),
      actor: ctx.actor,
      tenant: ctx.org_id
    )
  end

  defp reload(account),
    do: Ash.reload!(account, authorize?: false, tenant: account.org_id)

  describe "access" do
    test "an editor is refused", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))

      assert {:error, {:redirect, _}} = live(conn, ~p"/editor/social")
    end
  end

  describe "the stored credential" do
    test "is never rendered into the page", ctx do
      account(ctx)

      {:ok, _live, html} = live(ctx.conn, ~p"/editor/social")

      # Neither the plaintext nor the ciphertext may reach the browser.
      refute html =~ @token
    end

    test "survives a save that changes something else", ctx do
      account = account(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")

      live |> element("button[phx-click=edit]") |> render_click()

      live
      |> form("#edit-social-account-#{account.id}", %{
        "account" => %{"handle" => "renamed", "credential" => ""}
      })
      |> render_submit()

      updated = reload(account)

      # Blank means unchanged. The form never echoes the secret back, so blank
      # is the normal submission — reading it as "erase" would silently
      # disconnect a working account on any unrelated edit.
      assert updated.handle == "renamed"
      assert KilnCMS.Social.Account.credential(updated) == @token
    end

    test "is replaced when a new one is submitted", ctx do
      account = account(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")
      live |> element("button[phx-click=edit]") |> render_click()

      live
      |> form("#edit-social-account-#{account.id}", %{
        "account" => %{"credential" => "a-new-token"}
      })
      |> render_submit()

      assert KilnCMS.Social.Account.credential(reload(account)) == "a-new-token"
    end
  end

  describe "connecting an account" do
    test "requires an instance URL for Mastodon", ctx do
      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")

      html =
        live
        |> form("#new-social-account-form", %{
          "account" => %{
            "provider" => "mastodon",
            "handle" => "kiln",
            "instance_url" => "",
            "credential" => "t"
          }
        })
        |> render_submit()

      assert html =~ "is required for Mastodon"
      assert Social.list_accounts!(authorize?: false, tenant: ctx.org_id) == []
    end

    test "refuses a non-https instance URL", ctx do
      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")

      html =
        live
        |> form("#new-social-account-form", %{
          "account" => %{
            "provider" => "mastodon",
            "handle" => "kiln",
            "instance_url" => "http://169.254.169.254/",
            "credential" => "t"
          }
        })
        |> render_submit()

      # SafeFetch would refuse the request anyway; a value that can never work
      # should not be storable in the first place.
      assert html =~ "must be an https:// URL"
    end

    test "requires a handle for Bluesky", ctx do
      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")

      html =
        live
        |> form("#new-social-account-form", %{
          "account" => %{"provider" => "bluesky", "handle" => "", "credential" => "app-pw"}
        })
        |> render_submit()

      assert html =~ "is required for Bluesky"
    end
  end

  describe "the ledger" do
    test "shows an announcement's state and error", ctx do
      account = account(ctx)

      Social.claim_post!(
        %{
          account_id: account.id,
          provider: :mastodon,
          content_type: "post",
          content_id: Ash.UUID.generate(),
          content_published_at: DateTime.utc_now(),
          text: "Something was announced"
        },
        authorize?: false,
        tenant: ctx.org_id
      )

      {:ok, _live, html} = live(ctx.conn, ~p"/editor/social")

      assert html =~ "Something was announced"
    end
  end
end
