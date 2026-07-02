defmodule KilnCMSWeb.DynamicEntryEditorTest do
  @moduledoc """
  Phase 2 acceptance (decision D17): an admin defines a dynamic content type,
  then authors an entry end-to-end in the editor — create from the content
  index, edit title + custom fields, and publish — with no code deploy.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  @password "password123456"

  defp authed_user(role) do
    email = "dyn-#{System.unique_integer([:positive])}@example.com"

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

  defp define_recipe_type!(admin) do
    definition =
      CMS.create_type_definition!(
        %{name: "recipe#{System.unique_integer([:positive])}", label: "Recipe"},
        actor: admin
      )

    CMS.create_field_definition!(
      %{
        type_definition_id: definition.id,
        name: "servings",
        label: "Servings",
        field_type: :integer
      },
      actor: admin
    )

    definition
  end

  test "an admin authors and publishes a dynamic entry end-to-end", %{conn: conn} do
    admin = authed_user(:admin)
    definition = define_recipe_type!(admin)
    conn = log_in(conn, admin)

    # The content index offers the dynamic type and creates an entry.
    {:ok, index_lv, html} = live(conn, ~p"/editor")
    assert html =~ "New recipe"

    {:error, {:live_redirect, %{to: edit_path}}} =
      index_lv
      |> element("button[phx-value-kind='#{definition.name}']")
      |> render_click()

    entry = hd(ContentTypes.list!(definition.name, actor: admin))
    assert edit_path == "/editor/content/#{definition.name}/#{entry.id}"

    # The editor mounts the dynamic kind and renders its custom-field input.
    {:ok, editor_lv, html} = live(conn, edit_path)
    assert html =~ "Servings"

    editor_lv
    |> form("##{definition.name}-editor", %{
      "form" => %{
        "title" => "Pancakes",
        "slug" => "pancakes-#{System.unique_integer([:positive])}",
        "custom_fields" => %{"servings" => "4"}
      }
    })
    |> render_submit()

    saved = ContentTypes.get_record!(definition.name, entry.id, actor: admin)
    assert saved.title == "Pancakes"
    assert saved.custom_fields == %{"servings" => 4}

    # Publish straight from the editor's workflow controls (admin).
    render_click(editor_lv, "workflow", %{"action" => "publish"})

    published = ContentTypes.get_record!(definition.name, entry.id, actor: admin)
    assert published.state == :published

    # …and the entry is now publicly resolvable, scoped by its type.
    assert CMS.get_published_entry_by_slug!(published.slug, published.locale, definition.id,
             authorize?: false
           ).id == entry.id
  end

  test "the version sidebar and conflict handling work on dynamic entries", %{conn: conn} do
    admin = authed_user(:admin)
    definition = define_recipe_type!(admin)

    entry =
      ContentTypes.create!(
        definition.name,
        %{title: "Draft", slug: "d-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    conn = log_in(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/editor/content/#{definition.name}/#{entry.id}")

    # Someone else saves first → this editor's save hits the optimistic lock.
    {:ok, _} = CMS.update_entry(entry, %{title: "Changed elsewhere"}, actor: admin)

    html = lv |> form("##{definition.name}-editor") |> render_submit()
    assert html =~ "This content changed elsewhere"

    assert ContentTypes.get_record!(definition.name, entry.id, actor: admin).title ==
             "Changed elsewhere"
  end
end
