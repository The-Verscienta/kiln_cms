defmodule KilnCMSWeb.ContentEditorTitleTemplateTest do
  @moduledoc """
  A type with a `title_template` (#2287) owns its titles: the editor shows the
  title read-only with a hint, and the first save of the scaffold draft — and
  every autosave — derives it from the custom fields.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  @password "password123456"

  defp authed_user(role) do
    email = "titletpl-#{System.unique_integer([:positive])}@example.com"

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

  defp templated_type!(admin) do
    type =
      CMS.create_type_definition!(
        %{name: "ttl#{System.unique_integer([:positive])}", label: "Person"},
        actor: admin
      )

    for name <- ~w(last_name first_name) do
      CMS.create_field_definition!(
        %{type_definition_id: type.id, name: name, label: name, field_type: :string},
        actor: admin
      )
    end

    CMS.update_type_definition!(
      type,
      %{title_template: "{{ field.last_name }}, {{ field.first_name }}"},
      actor: admin
    )
  end

  defp scaffold!(admin, type) do
    ContentTypes.create!(
      type.name,
      %{title: "Untitled #{type.name}", slug: "untitled-#{System.unique_integer([:positive])}"},
      actor: admin
    )
  end

  test "the title is read-only with a hint on a draft", %{conn: conn} do
    admin = authed_user(:admin)
    type = templated_type!(admin)
    entry = scaffold!(admin, type)

    {:ok, lv, html} =
      conn |> log_in(admin) |> live(~p"/editor/content/#{type.name}/#{entry.id}")

    assert html =~ "Generated from the template on save"
    assert has_element?(lv, "input#form_title[readonly]")
  end

  test "the unsaved new-document form shows the title read-only too", %{conn: conn} do
    admin = authed_user(:admin)
    type = templated_type!(admin)

    {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/content/#{type.name}/new")

    assert html =~ "Generated from the template on save"
    assert has_element?(lv, "input#form_title[readonly]")
  end

  test "a type without a template keeps the title editable", %{conn: conn} do
    admin = authed_user(:admin)

    type =
      CMS.create_type_definition!(
        %{name: "plain#{System.unique_integer([:positive])}", label: "Plain"},
        actor: admin
      )

    entry = scaffold!(admin, type)
    {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/content/#{type.name}/#{entry.id}")

    refute html =~ "Generated from the template on save"
    refute has_element?(lv, "input#form_title[readonly]")
  end

  test "saving the scaffold draft derives the title and the slug", %{conn: conn} do
    admin = authed_user(:admin)
    type = templated_type!(admin)
    entry = scaffold!(admin, type)

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/content/#{type.name}/#{entry.id}")

    lv
    |> form("##{type.name}-editor", %{
      "form" => %{
        "custom_fields" => %{"last_name" => "Doe", "first_name" => "Jane"}
      }
    })
    |> render_submit()

    saved = ContentTypes.get_record!(type.name, entry.id, actor: admin)
    assert saved.title == "Doe, Jane"
    assert saved.slug == "doe-jane"
  end

  test "an autosave derives the title", %{conn: conn} do
    admin = authed_user(:admin)
    type = templated_type!(admin)
    entry = scaffold!(admin, type)

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/content/#{type.name}/#{entry.id}")

    lv
    |> form("##{type.name}-editor", %{
      "form" => %{"custom_fields" => %{"last_name" => "Roe", "first_name" => "Richard"}}
    })
    |> render_change()

    send(lv.pid, :autosave)
    _ = render(lv)

    saved = ContentTypes.get_record!(type.name, entry.id, actor: admin)
    assert saved.title == "Roe, Richard"
  end
end
