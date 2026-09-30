defmodule KilnCMSWeb.SummaryInteractiveContentTest do
  @moduledoc """
  No `<summary>` on a console page holds interactive content (#1804).

  HTML allows a `<summary>` only phrasing content that is not interactive: the
  summary IS the disclosure's button, so a link, button, field or focusable
  element inside it is a control inside a control. Clicking it toggles the
  `<details>` as well as doing its own thing, and a screen reader announces
  the summary's name with the inner control flattened into it. Chrome reports
  it as a page error ("Interactive element inside of a <summary> element"),
  which is how a beta tester found one on /media.

  The console layout's disclosures (the sidebar account menu, the notification
  bell, the mobile menu) and each page's own are all covered: both the dead
  render (the whole document, root layout included) and the connected one.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User

  @password "password123456"

  # What the HTML spec calls interactive content, plus anything focusable by
  # tabindex or editable, which Chrome's check counts too.
  @interactive [
    "a[href]",
    "button",
    "input:not([type=hidden])",
    "select",
    "textarea",
    "label",
    "details",
    "iframe",
    "embed",
    "audio[controls]",
    "video[controls]",
    "img[usemap]",
    "[tabindex]",
    "[contenteditable]"
  ]

  @selector Enum.map_join(@interactive, ", ", &"summary #{&1}")

  @pages ~w(/media /editor /editor/overview /editor/calendar /editor/tasks /editor/settings
            /editor/automation /editor/governance /editor/taxonomy /editor/menus /account)

  defp authed_user(role) do
    email = "summary-#{System.unique_integer([:positive])}@example.com"

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

  defp offenders(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(@selector)
    |> Enum.map(&LazyHTML.to_html/1)
  end

  # An unread notification, so the bell's summary renders its badge branch too.
  setup %{conn: conn} do
    admin = authed_user(:admin)

    :ok =
      KilnCMS.Notifications.record_in_app(%{
        user_id: admin.id,
        org_id: nil,
        event: :comment_mention,
        content_type: "page",
        content_id: Ash.UUID.generate(),
        title: "A draft",
        actor_name: "Jane Editor"
      })

    %{conn: log_in(conn, admin)}
  end

  test "the notification bell's badge branch is among what is checked", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/media")
    assert render(lv) =~ "bell-badge"
  end

  for path <- @pages do
    test "no <summary> on #{path} contains interactive content", %{conn: conn} do
      path = unquote(path)

      dead = conn |> get(path) |> html_response(200)
      assert offenders(dead) == [], "dead render of #{path}"

      {:ok, lv, _html} = live(conn, path)
      assert offenders(render(lv)) == [], "connected render of #{path}"
    end
  end

  # The check itself must be able to fail — a selector typo would pass every
  # page above.
  test "the check flags a control inside a summary" do
    html = ~s(<details><summary>Menu <button type="button">x</button></summary></details>)
    assert [_] = offenders(html)

    assert offenders(~s(<details><summary><span>Menu</span></summary><a href="/">x</a></details>)) ==
             []
  end
end
