defmodule KilnCMSWeb.LinkFieldsEditorTest do
  @moduledoc """
  Link fields in the content editor (R3, `docs/relationships-plan.md`): each
  row of a reference picker shows an input per link field, filled from the
  connection's stored `"link"` values; editing one saves it onto that
  connection, and moving or removing a row carries its values with it.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  require Ash.Query

  @password "password123456"

  defp authed_user(role) do
    email = "link-editor-#{System.unique_integer([:positive])}@example.com"

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

  defp uniq, do: System.unique_integer([:positive])

  defp page!(title, admin),
    do: CMS.create_page!(%{title: "#{title} #{uniq()}", slug: "lfe-#{uniq()}"}, actor: admin)

  setup do
    admin = authed_user(:admin)

    field =
      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: "ingredients",
          label: "Ingredients",
          field_type: :reference,
          target_type: "page",
          multiple: true
        },
        actor: admin
      )

    for {attrs, position} <-
          Enum.with_index([
            %{name: "quantity", label: "Quantity", field_type: :integer},
            %{name: "role", label: "Role", field_type: :select, options: ~w(main garnish)},
            %{name: "optional", label: "Optional", field_type: :boolean}
          ]) do
      CMS.create_field_definition!(
        Map.merge(attrs, %{link_of_id: field.id, position: position}),
        actor: admin
      )
    end

    flour = page!("Flour", admin)
    salt = page!("Salt", admin)

    post =
      CMS.create_post!(
        %{
          title: "Bread",
          slug: "lfe-#{uniq()}",
          custom_fields: %{
            "ingredients" => [
              %{"id" => flour.id, "link" => %{"quantity" => 500, "role" => "main"}},
              %{"id" => salt.id, "link" => %{"quantity" => 5, "role" => "garnish"}}
            ]
          }
        },
        actor: admin
      )

    %{admin: admin, flour: flour, salt: salt, post: post}
  end

  defp open_editor(conn, user, post) do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/post/#{post.id}")
    lv
  end

  defp input(id, link), do: "#cf-ref-ingredients-#{id}-link-#{link}"

  defp value(lv, selector) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
  end

  defp stored(post, admin),
    do: CMS.get_post!(post.id, actor: admin, tenant: post.org_id).custom_fields["ingredients"]

  defp links(value), do: Enum.map(value, &{&1["id"], &1["link"]})

  defp link_param(id, values),
    do: %{"form" => %{"_kiln_ref_link" => %{"ingredients" => %{id => values}}}}

  test "every row shows its connection's link values, labelled per record", ctx do
    lv = open_editor(ctx.conn, ctx.admin, ctx.post)

    assert value(lv, input(ctx.flour.id, "quantity")) == ["500"]
    assert value(lv, input(ctx.salt.id, "quantity")) == ["5"]
    assert has_element?(lv, "#{input(ctx.salt.id, "role")} option[value=garnish][selected]")

    assert has_element?(
             lv,
             ~s(#cf-ref-ingredients-#{ctx.flour.id}-link[role=group][aria-label^="Details for Flour"])
           )

    assert has_element?(
             lv,
             ~s(input#{input(ctx.flour.id, "quantity")}[name="form[_kiln_ref_link][ingredients][#{ctx.flour.id}][quantity]"])
           )
  end

  test "an edited link value saves onto its connection and its edge", ctx do
    lv = open_editor(ctx.conn, ctx.admin, ctx.post)

    lv
    |> form("#post-editor")
    |> render_submit(
      link_param(ctx.salt.id, %{"quantity" => "7", "role" => "main", "optional" => "true"})
    )

    assert links(stored(ctx.post, ctx.admin)) == [
             {ctx.flour.id, %{"quantity" => 500, "role" => "main", "optional" => false}},
             {ctx.salt.id, %{"quantity" => 7, "role" => "main", "optional" => true}}
           ]

    [edge] =
      KilnCMS.CMS.ContentLink
      |> Ash.Query.filter(source_id == ^ctx.post.id and target_id == ^ctx.salt.id)
      |> Ash.read!(authorize?: false)

    assert edge.metadata == %{"quantity" => 7, "role" => "main", "optional" => true}
  end

  test "an invalid link value is shown on the field, naming the connection", ctx do
    lv = open_editor(ctx.conn, ctx.admin, ctx.post)

    html =
      lv
      |> form("#post-editor")
      |> render_change(link_param(ctx.flour.id, %{"quantity" => "lots"}))

    assert html =~ "Quantity must be a whole number"
    assert html =~ "Flour"
  end

  test "moving and removing a row carries its values with it", ctx do
    lv = open_editor(ctx.conn, ctx.admin, ctx.post)

    lv
    |> element("#cf-ref-ingredients-#{ctx.salt.id} button[phx-value-dir=up]")
    |> render_click()

    assert value(lv, input(ctx.salt.id, "quantity")) == ["5"]

    lv |> form("#post-editor") |> render_submit()

    assert links(stored(ctx.post, ctx.admin)) == [
             {ctx.salt.id, %{"quantity" => 5, "role" => "garnish", "optional" => false}},
             {ctx.flour.id, %{"quantity" => 500, "role" => "main", "optional" => false}}
           ]

    lv
    |> element("#cf-ref-ingredients-#{ctx.salt.id} button[data-ref-remove]")
    |> render_click()

    assert value(lv, input(ctx.flour.id, "quantity")) == ["500"]
    refute has_element?(lv, input(ctx.salt.id, "quantity"))
  end

  test "a field without link fields renders no link inputs", ctx do
    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: "see_also",
        label: "See also",
        field_type: :reference,
        target_type: "page",
        multiple: true
      },
      actor: ctx.admin
    )

    {:ok, post} =
      CMS.update_post(ctx.post, %{custom_fields: %{"see_also" => [ctx.flour.id]}},
        actor: ctx.admin
      )

    lv = open_editor(ctx.conn, ctx.admin, post)
    assert has_element?(lv, "#cf-ref-see_also-#{ctx.flour.id}")
    refute has_element?(lv, "#cf-ref-see_also-#{ctx.flour.id}-link")
  end
end
