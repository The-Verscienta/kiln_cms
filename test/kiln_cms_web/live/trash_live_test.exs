defmodule KilnCMSWeb.TrashLiveTest do
  @moduledoc """
  `/editor/trash` — the only UI for restoring a soft-deleted document.

  It had no test at all, which is how Restore came to be broken on this path
  without anyone noticing: `@list_fields` selected a narrow column set for the
  list, and `:org_id` was not in it. Every hook on `:restore` needs it —
  `BustContentCache` reaches it through `Cache.key/5` (raising
  `Protocol.UndefinedError` on `%Ash.NotLoaded{}` inside an `after_action`, so
  the transaction rolled back), and since #1025 `FireArtifacts` puts it in the
  Oban args as well.

  Driven through the real LiveView event rather than by calling the action, so
  the select is exercised — that is the whole bug.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin do
    email = "trash-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

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

  test "restoring a trashed published page from the trash list works", %{conn: conn} do
    actor = authed_admin()

    page =
      CMS.create_page!(
        %{title: "Trashed", slug: "trash-#{System.unique_integer([:positive])}"},
        actor: actor
      )
      |> then(&CMS.publish_page!(&1, actor: actor))

    KilnCMS.DataCase.drain_oban()
    CMS.destroy_page!(page, actor: actor)
    KilnCMS.DataCase.drain_oban()

    {:ok, lv, html} = conn |> log_in(actor) |> live(~p"/editor/trash")
    assert html =~ "Trashed"

    lv
    |> element(~s(button[phx-click="restore"][phx-value-id="#{page.id}"]))
    |> render_click()

    KilnCMS.DataCase.drain_oban()

    # Back out of the trash, and live again.
    restored = CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)
    refute restored.archived_at
    assert restored.state == :published

    # And #1025: what trashing tore down is rebuilt.
    {:ok, artifacts} =
      KilnCMS.Firing.artifacts_for(:page, page.id, authorize?: false, tenant: page.org_id)

    refute artifacts == [], "restored from the trash UI with no artifacts"
  end
end
