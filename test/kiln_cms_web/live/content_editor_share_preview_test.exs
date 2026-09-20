defmodule KilnCMSWeb.ContentEditorSharePreviewTest do
  @moduledoc """
  The content editor's *Copy preview link*: mints a short-lived, read-only link
  to the draft (`KilnCMS.CMS.PreviewToken`) for someone without an editor
  account, replies with it for the clipboard hook, and shows it on screen.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.PreviewToken

  @password "password123456"

  defp authed_user(role, extra \\ %{}) do
    email = "ceshare-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        extra
      )
    )

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp open(conn, user, page) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
    |> live(~p"/editor/content/page/#{page.id}")
  end

  defp page!(actor),
    do:
      CMS.create_page!(
        %{title: "Share me", slug: "ceshare-#{System.unique_integer([:positive])}"},
        actor: actor
      )

  test "an editor copies a link that opens the draft for a guest", %{conn: conn} do
    editor = authed_user(:editor)
    page = page!(editor)
    {:ok, view, html} = open(conn, editor, page)

    assert html =~ "Copy preview link"
    refute has_element?(view, "#share-preview-link")

    html = view |> element("#share-preview-button") |> render_hook("share_preview", %{})
    assert_reply(view, %{url: url})

    # Shown as well as replied: the clipboard write can be refused.
    assert html =~ url
    assert has_element?(view, "#share-preview-copy[data-clipboard-text='#{url}']")

    "/preview/" <> token = URI.parse(url).path
    assert {:ok, %{type: "page", id: id}} = PreviewToken.verify(token)
    assert id == page.id

    {:ok, _guest, guest_html} = live(build_conn(), "/preview/#{token}/live")
    assert guest_html =~ "Share me"
    assert guest_html =~ "Shared draft preview"

    view
    |> element("#share-preview-link button[phx-click=dismiss_share_preview]")
    |> render_click()

    refute has_element?(view, "#share-preview-link")
  end

  test "an editor who reads this type only as a consumer is not offered the link", %{conn: conn} do
    admin = authed_user(:admin)
    page = admin |> page!() |> CMS.publish_page!(%{}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    # Scoped to posts: the published page opens (read-only), its drafts do not.
    scoped = authed_user(:editor, %{editable_types: ["post"], readable_types: ["post"]})
    {:ok, view, html} = open(conn, scoped, page)

    refute html =~ "Copy preview link"

    # A forged event is refused by the mint itself, not by the missing button.
    html = render_hook(view, "share_preview", %{})
    assert html =~ "You can&#39;t share a preview of this document."
    refute has_element?(view, "#share-preview-link")
  end
end
