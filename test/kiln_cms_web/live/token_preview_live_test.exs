defmodule KilnCMSWeb.TokenPreviewLiveTest do
  @moduledoc "Presence on the token preview (#379) — guests join the editors' shared session."
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.PreviewToken

  @password "password123456"

  defp editor_conn(name) do
    email = "tp-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      name: name,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp draft_page do
    Ash.Seed.seed!(KilnCMS.CMS.Page, %{
      title: "Guest Draft",
      slug: "tp-#{System.unique_integer([:positive])}",
      state: :draft,
      blocks: [%{type: :heading, content: "Hello guests", data: %{"level" => 1}, order: 0}]
    })
  end

  defp eventually(view, substring, present? \\ true, tries \\ 40) do
    html = render(view)

    cond do
      String.contains?(html, substring) == present? ->
        html

      tries == 0 ->
        flunk("expected #{substring} #{if present?, do: "in", else: "gone from"} render")

      true ->
        Process.sleep(25) && eventually(view, substring, present?, tries - 1)
    end
  end

  test "a valid token renders the draft with the shared ribbon", %{conn: conn} do
    page = draft_page()
    token = PreviewToken.sign(page)

    {:ok, _lv, html} = live(conn, "/preview/#{token}/live")

    assert html =~ "Guest Draft"
    assert html =~ "Shared draft preview"
  end

  test "an invalid token shows a dead-link notice, never content", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/preview/garbage-token/live")

    assert html =~ "expired"
    refute html =~ "Guest Draft"
  end

  test "a guest and an editor pop-out viewer see each other", %{conn: conn} do
    page = draft_page()
    token = PreviewToken.sign(page)

    {:ok, guest, _} = live(conn, "/preview/#{token}/live")
    {:ok, editor, _} = live(editor_conn("Edna"), ~p"/editor/preview/page/#{page.id}")

    # The editor sees the anonymous guest; the guest sees the editor by name.
    assert eventually(editor, "Guest") =~ "2 viewing"
    assert eventually(guest, "Edna") =~ "2 viewing"

    # An editor cursor move lands on the guest's screen.
    render_hook(editor, "cursor", %{"x" => 0.5, "y" => 0.5})
    assert render(guest) =~ "remote-cursor"
  end

  test "a guest can pick a display name that co-viewers see", %{conn: conn} do
    page = draft_page()
    token = PreviewToken.sign(page)

    {:ok, guest, _} = live(conn, "/preview/#{token}/live")
    {:ok, editor, _} = live(editor_conn("Edna"), ~p"/editor/preview/page/#{page.id}")
    eventually(editor, "Guest")

    guest |> form("#guest-name-form", %{"name" => "Priya (agency)"}) |> render_submit()

    assert eventually(editor, "Priya (agency)")
  end

  test "the guest view live-updates when the editor broadcasts a preview update", %{conn: conn} do
    page = draft_page()
    token = PreviewToken.sign(page)

    {:ok, guest, _} = live(conn, "/preview/#{token}/live")

    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      KilnCMSWeb.PreviewLive.topic("page", page.id),
      {:preview_update, %{title: "Retitled live", blocks: []}}
    )

    assert eventually(guest, "Retitled live")
  end

  test "a guest ignores the editors' locale-switch broadcast (#378)", %{conn: conn} do
    page = draft_page()
    token = PreviewToken.sign(page)

    {:ok, guest, _} = live(conn, "/preview/#{token}/live")

    Phoenix.PubSub.broadcast(
      KilnCMS.PubSub,
      KilnCMSWeb.PreviewLive.topic("page", page.id),
      {:preview_switch, Ash.UUID.generate()}
    )

    # Still alive and still on the same page (a navigate would tear it down).
    assert render(guest) =~ "Guest Draft"
  end

  test "a browser opening the JSON link is redirected to the live view", %{conn: conn} do
    page = draft_page()
    token = PreviewToken.sign(page)

    conn = conn |> put_req_header("accept", "text/html") |> get("/preview/#{token}")
    assert redirected_to(conn) == "/preview/#{token}/live"
  end

  test "the JSON surface is unchanged for headless consumers", %{conn: conn} do
    page = draft_page()
    token = PreviewToken.sign(page)

    conn = conn |> put_req_header("accept", "application/json") |> get("/preview/#{token}")
    assert %{"data" => %{"title" => "Guest Draft"}} = json_response(conn, 200)
  end
end
