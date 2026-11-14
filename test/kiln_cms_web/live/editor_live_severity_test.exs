defmodule KilnCMSWeb.EditorLiveSeverityTest do
  @moduledoc """
  The content list has no severity picker, so a publish from it that touches a
  site-listed safety field is refused and points at the editor; every other
  publish goes through (`KilnCMS.CMS.Severity`).
  """
  # `async: false`: the safety-field list is one cached row per organization,
  # and every test here uses the default org.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post

  @password "password123456"

  defp authed_user(role) do
    email = "sev-list-#{System.unique_integer([:positive])}@example.com"

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
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp draft(resource, title) do
    Ash.Seed.seed!(resource, %{
      title: title,
      slug: "sev-list-#{System.unique_integer([:positive])}",
      state: :draft
    })
  end

  defp list_safety(admin, fields) do
    CMS.save_site_safety_fields!(%{fields: fields},
      actor: admin,
      tenant: KilnCMS.Accounts.default_org_id()
    )
  end

  setup do
    admin = authed_user(:admin)
    # Only pages carry a listed field; posts are plain.
    list_safety(admin, %{"page" => ["title"]})
    on_exit(fn -> list_safety(admin, %{}) end)
    %{admin: admin}
  end

  test "row publish of a draft with a listed field is refused and stays a draft",
       %{conn: conn, admin: admin} do
    page = draft(Page, "Dosage")

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor")

    html =
      lv
      |> element(~s(button[phx-click="publish"][phx-value-id="#{page.id}"]))
      |> render_click()

    assert html =~ "touches a safety field"
    assert CMS.get_page!(page.id, authorize?: false).state == :draft
  end

  test "row publish of a draft with no listed field succeeds", %{conn: conn, admin: admin} do
    post = draft(Post, "Plain")

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor")

    lv
    |> element(~s(button[phx-click="publish"][phx-value-id="#{post.id}"]))
    |> render_click()

    assert CMS.get_post!(post.id, authorize?: false).state == :published
  end

  test "bulk publish publishes the plain ones, skips safety ones and counts them",
       %{conn: conn, admin: admin} do
    page = draft(Page, "Dosage")
    post = draft(Post, "Plain")

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor")

    lv |> element(~s(input[phx-value-key="page:#{page.id}"])) |> render_click()
    lv |> element(~s(input[phx-value-key="post:#{post.id}"])) |> render_click()
    lv |> element("button[phx-value-action='publish']") |> render_click()
    html = lv |> element("button[phx-click='confirm_bulk']") |> render_click()

    assert CMS.get_page!(page.id, authorize?: false).state == :draft
    assert CMS.get_post!(post.id, authorize?: false).state == :published
    assert html =~ "1 updated, 1 skipped"
    assert html =~ "open each in the editor"
    # Skipped only for the safety field: that sentence is the whole explanation,
    # not followed by the generic reason line (#2894).
    refute html =~ "A row is skipped when"
  end
end
