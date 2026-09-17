defmodule KilnCMSWeb.SocialAccountActionsTest do
  @moduledoc """
  The row actions on `/editor/social` (#497): test the connection, turn an
  account off, remove it, and the edit panel around them.

  `social_live_test.exs` guards the credential — never rendered, never erased
  by a blank field. What it does not drive is the rest of the row, where each
  button carries an account id back from the page. Two of them are the ones
  that matter: **off** is how someone stops a site posting to an account they
  no longer control, and **remove** takes the credential with it. Both must act
  on the row they name, or on nothing.

  `verify` is the only one that leaves the machine, so its provider call is
  stubbed: what is being tested is what the page says about each answer, not
  Mastodon's API.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Social

  @token "super-secret-token"
  @password "password123456"

  setup %{conn: conn} do
    admin = authed_user(:admin)

    %{
      conn: log_in(conn, admin),
      actor: admin,
      org_id: KilnCMS.Accounts.default_org_id()
    }
  end

  defp authed_user(role) do
    email = "social-actions-#{System.unique_integer([:positive])}@example.com"

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
          handle: "kiln#{System.unique_integer([:positive])}",
          instance_url: "https://mastodon.test",
          credential: @token
        },
        attrs
      ),
      actor: ctx.actor,
      tenant: ctx.org_id
    )
  end

  # One account per provider per org (`:one_per_provider`), so a second account
  # in a test is the other provider.
  defp bluesky(ctx, handle) do
    Social.create_account!(
      %{provider: :bluesky, handle: handle, credential: @token},
      actor: ctx.actor,
      tenant: ctx.org_id
    )
  end

  defp reload(account),
    do: Ash.reload!(account, authorize?: false, tenant: account.org_id)

  defp accounts(ctx), do: Social.list_accounts!(actor: ctx.actor, tenant: ctx.org_id)

  describe "testing the connection" do
    test "an instance that accepts the credential says so", ctx do
      account = account(ctx)
      Req.Test.stub(KilnCMS.Social, fn conn -> Plug.Conn.send_resp(conn, 200, "{}") end)

      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")

      html =
        live
        |> element(~s(button[phx-value-id="#{account.id}"][phx-click=verify]))
        |> render_click()

      assert html =~ "Connection works."
    end

    test "a rejected credential names the status, rather than claiming it works", ctx do
      account = account(ctx)
      Req.Test.stub(KilnCMS.Social, fn conn -> Plug.Conn.send_resp(conn, 401, "nope") end)

      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")
      html = render_click(live, "verify", %{"id" => account.id})

      # The point of the button is to tell someone their posting is broken
      # before a publish does. A silent success here is the whole failure.
      assert html =~ "Connection failed: instance answered 401"
      refute html =~ "Connection works."
    end

    test "an unreachable instance is reported, not raised", ctx do
      account = account(ctx)
      Req.Test.stub(KilnCMS.Social, &Req.Test.transport_error(&1, :econnrefused))

      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")
      html = render_click(live, "verify", %{"id" => account.id})

      assert html =~ "Connection failed:"
    end

    test "an id that is not an account here is refused", ctx do
      account(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")
      html = render_click(live, "verify", %{"id" => Ash.UUID.generate()})

      assert html =~ "Couldn&#39;t test that account."
    end
  end

  describe "turning an account off" do
    test "toggle disables it, and toggling again brings it back", ctx do
      account = account(ctx)
      assert account.enabled

      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")
      render_click(live, "toggle_enabled", %{"id" => account.id})

      refute reload(account).enabled

      render_click(live, "toggle_enabled", %{"id" => account.id})
      assert reload(account).enabled
    end

    test "it toggles the account it names, and leaves the others alone", ctx do
      first = account(ctx, %{handle: "first"})
      second = bluesky(ctx, "second.bsky.social")

      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")
      render_click(live, "toggle_enabled", %{"id" => second.id})

      assert reload(first).enabled
      refute reload(second).enabled
    end

    test "an id that is not an account here changes nothing", ctx do
      account = account(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")
      html = render_click(live, "toggle_enabled", %{"id" => Ash.UUID.generate()})

      assert html =~ "Couldn&#39;t update that account."
      assert reload(account).enabled
    end
  end

  describe "removing an account" do
    test "remove deletes the row, and the page stops listing it", ctx do
      account = account(ctx, %{handle: "goodbye"})

      {:ok, live, html} = live(ctx.conn, ~p"/editor/social")
      assert html =~ "goodbye"

      html = render_click(live, "delete", %{"id" => account.id})

      assert html =~ "Account removed."
      refute html =~ "goodbye"
      assert accounts(ctx) == []
    end

    test "it removes the account it names, and leaves the others", ctx do
      kept = account(ctx, %{handle: "kept"})
      doomed = bluesky(ctx, "doomed.bsky.social")

      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")
      render_click(live, "delete", %{"id" => doomed.id})

      assert [remaining] = accounts(ctx)
      assert remaining.id == kept.id
    end

    test "an id that is not an account here removes nothing", ctx do
      account(ctx)

      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")
      html = render_click(live, "delete", %{"id" => Ash.UUID.generate()})

      assert html =~ "Couldn&#39;t remove that account."
      assert length(accounts(ctx)) == 1
    end
  end

  describe "the edit panel" do
    test "edit opens the row's own form, and cancel closes it", ctx do
      account = account(ctx, %{handle: "editable"})

      {:ok, live, html} = live(ctx.conn, ~p"/editor/social")
      refute html =~ "edit-social-account-#{account.id}"

      html = render_click(live, "edit", %{"id" => account.id})
      assert html =~ "edit-social-account-#{account.id}"

      html = render_click(live, "cancel_edit", %{})
      refute html =~ "edit-social-account-#{account.id}"
    end

    test "an edit that the resource rejects keeps the panel open and saves nothing", ctx do
      account = account(ctx, %{handle: "keepme"})

      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")
      render_click(live, "edit", %{"id" => account.id})

      html =
        live
        |> form("#edit-social-account-#{account.id}", %{
          "account" => %{"instance_url" => "http://insecure.test"}
        })
        |> render_submit()

      # Still open — closing it would look like the change had been taken.
      assert html =~ "edit-social-account-#{account.id}"
      assert reload(account).instance_url == "https://mastodon.test"
    end

    test "a delete closes the open panel, even when it is another account's", ctx do
      edited = account(ctx, %{handle: "being-edited"})
      other = bluesky(ctx, "other.bsky.social")

      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")

      assert render_click(live, "edit", %{"id" => edited.id}) =~
               "edit-social-account-#{edited.id}"

      html = render_click(live, "delete", %{"id" => other.id})

      # The list behind the panel just changed, so the panel is closed rather
      # than left open over a list it no longer matches.
      refute html =~ "edit-social-account-#{edited.id}"
      assert [remaining] = accounts(ctx)
      assert remaining.id == edited.id
    end

    test "validating an edit reports the problem without writing it", ctx do
      account = account(ctx, %{handle: "steady"})

      {:ok, live, _html} = live(ctx.conn, ~p"/editor/social")
      render_click(live, "edit", %{"id" => account.id})

      live
      |> form("#edit-social-account-#{account.id}", %{
        "account" => %{"instance_url" => "http://insecure.test"}
      })
      |> render_change()

      assert reload(account).instance_url == "https://mastodon.test"
    end
  end
end
