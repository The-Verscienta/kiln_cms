defmodule KilnCMSWeb.PluginListFieldEditorTest do
  @moduledoc """
  The content editor's input for a list of a plugin field type (#2680): the
  generic list input, each item an input of the type's own `input_type/0`
  with its `input_attrs/1`; adding, removing, reordering and saving as for a
  core list; repeats kept or dropped as the type says; no client hook on the
  item inputs; and a held list (its type no longer takes lists) shown as
  text, with nothing posted for it, so saving keeps it.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "plfe-#{System.unique_integer([:positive])}@example.com"

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

  defp define!(admin, attrs),
    do: CMS.create_field_definition!(Map.put(attrs, :content_type, :page), actor: admin)

  defp signed_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  setup %{conn: conn} do
    admin = authed_user(:admin)
    n = System.unique_integer([:positive])
    stars = "plfe_stars_#{n}"
    tags = "plfe_tags_#{n}"
    tag = "plfe_tag_#{n}"
    held = "plfe_held_#{n}"

    define!(admin, %{name: stars, label: "Stars", field_type: :stars, multiple: true, position: 0})

    define!(admin, %{name: tags, label: "Tags", field_type: :tag, multiple: true, position: 1})
    define!(admin, %{name: tag, label: "One tag", field_type: :tag, position: 2})
    rating = define!(admin, %{name: held, label: "Held", field_type: :rating, position: 3})

    page =
      CMS.create_page!(
        %{
          title: "Lists",
          slug: "plfe-#{n}",
          custom_fields: %{stars => [3], tags => ["red"], tag => "solo"}
        },
        actor: admin
      )

    # A list of a type that takes lists no more, as an earlier plugin left it.
    KilnCMS.Repo.query!("UPDATE field_definitions SET multiple = true WHERE id = $1", [
      Ecto.UUID.dump!(rating.id)
    ])

    KilnCMS.Repo.query!(
      "UPDATE pages SET custom_fields = custom_fields || $1 WHERE id = $2",
      [%{held => [3, 4]}, Ecto.UUID.dump!(page.id)]
    )

    {:ok, lv, _html} = conn |> signed_in(admin) |> live(~p"/editor/content/page/#{page.id}")

    %{admin: admin, page: page, lv: lv, stars: stars, tags: tags, tag: tag, held: held}
  end

  defp item(field, n), do: "#custom-field-#{field}-#{n}"

  defp item_value(lv, field, n) do
    lv
    |> element(item(field, n))
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("value")
    |> List.first()
  end

  defp add(lv, field, value) do
    lv
    |> element("#custom-field-#{field}-entry")
    |> render_hook("list_item_add", %{"field" => field, "item" => value})
  end

  defp stored(ctx), do: CMS.get_page!(ctx.page.id, actor: ctx.admin).custom_fields

  describe "a list of a plugin type" do
    test "each item is the type's own input, with its attributes", ctx do
      assert has_element?(
               ctx.lv,
               ~s(#{item(ctx.stars, 0)}[type=number][min="1"][max="5"][name="form[custom_fields][#{ctx.stars}][]"][value="3"])
             )

      assert has_element?(
               ctx.lv,
               ~s(#custom-field-#{ctx.stars}-entry[type=number][phx-hook=TermPicker][data-split=lines])
             )

      assert has_element?(ctx.lv, ~s(#custom-field-#{ctx.tags}-entry[data-split=lines]))
      refute has_element?(ctx.lv, "#custom-field-#{ctx.tags}-add")
    end

    test "its hook is left off a list field's inputs, and kept on a single one", ctx do
      refute has_element?(ctx.lv, "#cf-hook-#{ctx.tags}")
      assert has_element?(ctx.lv, "#cf-hook-#{ctx.tag}[phx-hook]")
    end

    test "stars repeat; tags do not, judged as the type casts them", ctx do
      add(ctx.lv, ctx.stars, "3")
      assert item_value(ctx.lv, ctx.stars, 1) == "3"

      add(ctx.lv, ctx.tags, " RED ")
      refute has_element?(ctx.lv, item(ctx.tags, 1))

      add(ctx.lv, ctx.tags, "blue")
      assert item_value(ctx.lv, ctx.tags, 1) == "blue"
    end

    test "adds, removes, reorders and saves through cast/2", ctx do
      add(ctx.lv, ctx.stars, "5")
      add(ctx.lv, ctx.stars, "1")

      ctx.lv
      |> element("#custom-field-#{ctx.stars}-items")
      |> render_hook("list_item_reorder", %{"field" => ctx.stars, "order" => ["2", "0", "1"]})

      assert item_value(ctx.lv, ctx.stars, 0) == "1"

      ctx.lv
      |> element("#cf-item-#{ctx.stars}-2 button[phx-click=list_item_remove]")
      |> render_click()

      add(ctx.lv, ctx.tags, "Green")

      ctx.lv |> form("#page-editor") |> render_submit()

      fields = stored(ctx)
      assert fields[ctx.stars] == [1, 3]
      assert fields[ctx.tags] == ["red", "green"]
    end

    test "an item the type refuses is named by the field's error", ctx do
      html = add(ctx.lv, ctx.stars, "9")
      assert html =~ "item 2 must be a whole number from 1 to 5"
    end
  end

  describe "a held list" do
    test "is shown as text with a note, and has no inputs", ctx do
      assert has_element?(ctx.lv, "#custom-field-#{ctx.held}-held-items li", "3")
      assert has_element?(ctx.lv, "#custom-field-#{ctx.held}-held-items li", "4")
      assert has_element?(ctx.lv, "#cf-held-list-#{ctx.held}", "no longer takes a list")
      refute has_element?(ctx.lv, ~s(input[name^="form[custom_fields][#{ctx.held}]"]))
      refute has_element?(ctx.lv, "#custom-field-#{ctx.held}-entry")
    end

    test "its list events change nothing, and saving keeps it", ctx do
      render_hook(ctx.lv, "list_item_add", %{"field" => ctx.held, "item" => "5"})
      render_hook(ctx.lv, "list_item_remove", %{"field" => ctx.held, "index" => "0"})

      add(ctx.lv, ctx.stars, "2")
      html = ctx.lv |> form("#page-editor") |> render_submit()

      refute html =~ "no longer takes a list of values"
      fields = stored(ctx)
      assert fields[ctx.held] == [3, 4]
      assert fields[ctx.stars] == [3, 2]
    end
  end
end
