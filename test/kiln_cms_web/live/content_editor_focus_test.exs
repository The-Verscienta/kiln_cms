defmodule KilnCMSWeb.ContentEditorFocusTest do
  @moduledoc """
  Field-level deep-link focus in the structured editor (#355): opening
  `/editor/content/:type/:id?focus=<field>` renders the FocusField hook marker
  carrying the field name, and the anchors the hook targets exist — a custom
  field's stable input id, a core field's `phx-value-field` attribute. The
  scroll/pulse/focus behavior itself is the JS hook's job (not exercisable in
  LiveViewTest); these tests pin the server-rendered contract it relies on.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "focus-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "focus-#{System.unique_integer([:positive])}"

  test "?focus=<custom field> renders the hook marker and the field's stable anchor",
       %{conn: conn} do
    admin = authed_user(:admin)

    definition =
      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "reading_time_#{System.unique_integer([:positive])}",
          label: "Reading time",
          field_type: :string
        },
        actor: admin
      )

    page = CMS.create_page!(%{title: "Focus target", slug: slug()}, actor: admin)

    {:ok, _lv, html} =
      conn
      |> log_in(admin)
      |> live(~p"/editor/content/page/#{page.id}?focus=#{definition.name}")

    # The marker the FocusField JS hook mounts on, carrying the field name.
    assert html =~ ~r/id="focus-field"[^>]*phx-hook="FocusField"/
    assert html =~ ~s(data-kiln-focus="#{definition.name}")
    # The anchor the hook scrolls to: the custom field's stable input id.
    assert html =~ ~s(id="custom-field-#{definition.name}")
  end

  test "?focus=<core field> works via the presence-tracking anchor", %{conn: conn} do
    editor = authed_user(:editor)
    page = CMS.create_page!(%{title: "Core focus", slug: slug()}, actor: editor)

    {:ok, _lv, html} =
      conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}?focus=title")

    assert html =~ ~s(data-kiln-focus="title")
    # The anchor for core fields: field_attrs/1's presence-tracking attribute.
    assert html =~ ~s(phx-value-field="title")
  end

  test "without ?focus= no marker renders", %{conn: conn} do
    editor = authed_user(:editor)
    page = CMS.create_page!(%{title: "No focus", slug: slug()}, actor: editor)

    {:ok, _lv, html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

    refute html =~ "FocusField"
  end
end
