defmodule KilnCMSWeb.FormatFieldEditorTest do
  @moduledoc """
  The content editor's widgets for the built-in format field types (#2278):
  the JSON textarea (pretty-printed, and showing what was typed after a failed
  parse), and a colour field saved untouched.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin do
    email = "ffe-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
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

  defp editor(conn, admin, fields) do
    for {name, type} <- [{"payload", :json}, {"accent", :color}, {"opens", :time}] do
      CMS.create_field_definition!(
        %{content_type: :page, name: name, label: String.capitalize(name), field_type: type},
        actor: admin
      )
    end

    page =
      CMS.create_page!(
        %{title: "Fmt", slug: "ffe-#{System.unique_integer([:positive])}", custom_fields: fields},
        actor: admin
      )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)

    {:ok, lv, html} = live(conn, ~p"/editor/content/page/#{page.id}")
    {lv, html, page}
  end

  test "a json field is a textarea showing the stored structure pretty-printed", %{conn: conn} do
    {_lv, html, _page} = editor(conn, authed_admin(), %{"payload" => %{"a" => [1, 2]}})

    assert html =~ ~r/<textarea[^>]*id="custom-field-payload"/
    assert html =~ "&quot;a&quot;: ["

    assert html =~ ~r/<input[^>]*id="custom-field-opens"[^>]*type="time"/ or
             html =~ ~r/<input[^>]*type="time"[^>]*id="custom-field-opens"/
  end

  test "a failed json parse keeps the typed text and shows the message", %{conn: conn} do
    {lv, _html, _page} = editor(conn, authed_admin(), %{"payload" => %{"a" => 1}})

    html =
      lv
      |> form("#page-editor", %{"form" => %{"custom_fields" => %{"payload" => "{oops"}}})
      |> render_change()

    assert html =~ "must be valid JSON"
    assert html =~ "{oops"
  end

  test "a colour field left blank is not filled in on save", %{conn: conn} do
    admin = authed_admin()
    {lv, html, page} = editor(conn, admin, %{})

    assert html =~ ~r/id="custom-field-accent"[^>]*pattern=/ or
             html =~ ~r/pattern="[^"]*"[^>]*id="custom-field-accent"/

    lv |> form("#page-editor") |> render_submit()

    saved = CMS.get_page!(page.id, actor: admin)
    refute Map.has_key?(saved.custom_fields, "accent")
  end
end
