defmodule KilnCMSWeb.ReverseFieldTest do
  @moduledoc """
  Reverse fields in the admin (R4, `docs/relationships-plan.md`): the fields
  admin names a reference's other side in plain words, and the target's
  editor lists the records connecting to it — read-only, with each
  connection's details, a page at a time, and never a source the editor
  could not open.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMSWeb.ContentEditor.ReverseField

  @password "password123456"

  defp authed_user(role, attrs \\ %{}) do
    email = "reverse-lv-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
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

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp uniq, do: System.unique_integer([:positive])
  defp slug, do: "reverse-lv-#{uniq()}"

  setup do
    admin = authed_user(:admin)

    field =
      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: "ingredients_#{uniq()}",
          label: "Ingredients",
          field_type: :reference,
          target_type: "page",
          multiple: true
        },
        actor: admin
      )

    %{admin: admin, field: field}
  end

  describe "the fields admin" do
    test "names the other side in plain words and reads it back in the summary", ctx do
      {:ok, lv, _html} = build_conn() |> log_in(ctx.admin) |> live(~p"/editor/fields")

      lv |> element("#field-#{ctx.field.id} button[phx-click=edit]") |> render_click()
      assert has_element?(lv, "#edit-field-inverse-#{ctx.field.id}", "What Page calls this")

      lv
      |> form("#edit-field-#{ctx.field.id}",
        field_definition: %{inverse_label: "Posts using this page"}
      )
      |> render_submit()

      field = CMS.get_field_definition!(ctx.field.id, authorize?: false)

      assert {field.inverse_label, field.inverse_name} ==
               {"Posts using this page", "posts_using_this_page"}

      assert lv |> element("#field-#{ctx.field.id}-links") |> render() =~
               "Each Page lists them as “Posts using this page”"

      # Emptying the name removes the list, machine name and all.
      lv |> element("#field-#{ctx.field.id} button[phx-click=edit]") |> render_click()

      lv
      |> form("#edit-field-#{ctx.field.id}", field_definition: %{inverse_label: ""})
      |> render_submit()

      field = CMS.get_field_definition!(ctx.field.id, authorize?: false)
      assert {field.inverse_label, field.inverse_name} == {nil, nil}
    end

    test "is not offered for other field types", ctx do
      {:ok, lv, _html} = build_conn() |> log_in(ctx.admin) |> live(~p"/editor/fields")

      lv
      |> form("#new-field-form", field_definition: %{field_type: "string"})
      |> render_change()

      refute has_element?(lv, "#new-field-inverse")
    end
  end

  describe "the target's editor" do
    setup ctx do
      field =
        CMS.update_field_definition!(ctx.field, %{inverse_label: "Posts using this page"},
          actor: ctx.admin
        )

      CMS.create_field_definition!(
        %{link_of_id: field.id, name: "quantity", label: "Quantity", field_type: :integer},
        actor: ctx.admin
      )

      target = CMS.create_page!(%{title: "Flour", slug: slug()}, actor: ctx.admin)
      item = [%{"id" => target.id, "link" => %{"quantity" => "250"}}]

      sources =
        for title <- ["Bread", "Cake"] do
          CMS.create_post!(%{title: title, slug: slug(), custom_fields: %{field.name => item}},
            actor: ctx.admin
          )
        end

      %{field: field, target: target, sources: sources}
    end

    defp open(user, record, type \\ "page") do
      {:ok, lv, _html} =
        build_conn() |> log_in(user) |> live(~p"/editor/content/#{type}/#{record.id}")

      lv
    end

    defp root(field), do: "#reverse-field-post-#{field.name}"

    test "lists the records connecting here, read-only, with their details", ctx do
      lv = open(ctx.admin, ctx.target)
      root = root(ctx.field)

      assert has_element?(lv, root, "Posts using this page")
      assert has_element?(lv, root, "2 connected")

      assert has_element?(
               lv,
               root,
               "Post records that connect to this one through their Ingredients field."
             )

      [bread, cake] = ctx.sources
      assert has_element?(lv, "#{root}-#{bread.id}", "Bread")
      assert has_element?(lv, "#{root}-#{bread.id}-details", "Quantity: 250")
      assert has_element?(lv, "#{root}-#{cake.id} a[href='/editor/content/post/#{cake.id}']")

      # Nothing of the list posts into the editor form: the connections are
      # the posts' values, not this page's.
      refute has_element?(lv, "#{root}-items input")
    end

    test "a record of another type shows no reverse field", ctx do
      post = hd(ctx.sources)
      lv = open(ctx.admin, post, "post")
      refute has_element?(lv, "[data-reverse-field]")
    end

    test "pages through a long list", ctx do
      item = [%{"id" => ctx.target.id}]

      for n <- 1..ReverseField.page_size() do
        CMS.create_post!(
          %{
            title: "Z#{String.pad_leading("#{n}", 2, "0")}",
            slug: slug(),
            custom_fields: %{ctx.field.name => item}
          },
          actor: ctx.admin
        )
      end

      lv = open(ctx.admin, ctx.target)
      root = root(ctx.field)
      total = ReverseField.page_size() + 2

      assert has_element?(lv, root, "1–#{ReverseField.page_size()} of #{total}")
      assert has_element?(lv, "#{root}-#{hd(ctx.sources).id}")

      lv |> element("#{root} button", "Next") |> render_click()

      assert has_element?(lv, root, "#{ReverseField.page_size() + 1}–#{total} of #{total}")
      refute has_element?(lv, "#{root}-#{hd(ctx.sources).id}")
    end

    test "a source the editor may not read is neither listed nor counted", ctx do
      # An editor scoped to pages (#332) cannot open posts, so the posts
      # connecting here are not theirs to see — not even as a count.
      editor = authed_user(:editor, %{readable_types: ["page"], editable_types: ["page"]})
      lv = open(editor, ctx.target)
      root = root(ctx.field)

      assert has_element?(lv, root, "Nothing connects to this record yet.")
      refute has_element?(lv, "#{root}-#{hd(ctx.sources).id}")
      refute has_element?(lv, root, "connected")
    end
  end
end
