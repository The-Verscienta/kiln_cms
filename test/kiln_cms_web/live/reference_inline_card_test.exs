defmodule KilnCMSWeb.ReferenceInlineCardTest do
  @moduledoc """
  The record card of a reference field with `edit_inline` (#2283, PRs 1 and
  2a): a disclosure on each connected row the actor may write opens a card
  with the record's title and plain fields as inputs; a record the actor cannot write or
  read has no card, a forged `inline_toggle` opens nothing, and a field the
  actor's read grant hides is not rendered.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role, attrs \\ %{}) do
    email = "ref-inl-#{System.unique_integer([:positive])}@example.com"

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

  defp uniq, do: System.unique_integer([:positive])

  defp field!(admin, name, extra \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: name,
          label: "Linked #{name}",
          field_type: :reference,
          target_type: "page",
          multiple: true,
          edit_inline: true
        },
        extra
      ),
      actor: admin
    )
  end

  defp page_field!(admin, name, type, extra \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :page, name: name, label: name, field_type: type}, extra),
      actor: admin
    )
  end

  defp post_with!(admin, field, pages) do
    value = Enum.map(pages, &%{"id" => &1.id, "type" => "page"})

    CMS.create_post!(
      %{title: "Host", slug: "rin-#{uniq()}", custom_fields: %{field => value}},
      actor: admin
    )
  end

  defp open_editor(conn, user, post) do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/post/#{post.id}")
    lv
  end

  defp toggle(lv, field, page_id),
    do: element(lv, "#cf-ref-#{field}-#{page_id}-inline-toggle")

  defp card(lv, field, page_id), do: element(lv, "#cf-ref-#{field}-#{page_id}-inline-card")

  setup do
    admin = authed_user(:admin)
    page_field!(admin, "rin_kicker", :string)
    page_field!(admin, "rin_stars", :integer)
    page_field!(admin, "rin_secret", :string, %{private: true})
    page_field!(admin, "rin_body", :media)

    page =
      CMS.create_page!(
        %{
          title: "Child #{uniq()}",
          slug: "rin-#{uniq()}",
          custom_fields: %{
            "rin_kicker" => "Hello kicker",
            "rin_stars" => 4,
            "rin_secret" => "hush"
          }
        },
        actor: admin
      )

    %{admin: admin, page: page}
  end

  describe "the card" do
    test "an editor opens a card with the title and plain fields as inputs", ctx do
      field!(ctx.admin, "rin_a")
      post = post_with!(ctx.admin, "rin_a", [ctx.page])
      editor = authed_user(:editor)
      lv = open_editor(build_conn(), editor, post)

      refute has_element?(lv, "#cf-ref-rin_a-#{ctx.page.id}-inline-card")
      assert has_element?(lv, "#cf-ref-rin_a-#{ctx.page.id}-inline-toggle")
      assert render(toggle(lv, "rin_a", ctx.page.id)) =~ ~s(aria-expanded="false")

      render_click(toggle(lv, "rin_a", ctx.page.id))

      assert render(toggle(lv, "rin_a", ctx.page.id)) =~ ~s(aria-expanded="true")
      html = render(card(lv, "rin_a", ctx.page.id))
      assert html =~ ctx.page.title
      assert html =~ "Hello kicker"
      assert html =~ "Draft: readers do not see this record"
      assert html =~ "Open in the full editor"
      assert html =~ ~s(name="_kiln_inline[rin_a][#{ctx.page.id}][title]")
      assert html =~ ~s(name="_kiln_inline[rin_a][#{ctx.page.id}][custom_fields][rin_kicker]")
      # A media field is never an input here: it is the full editor's.
      refute html =~ "rin_body"
      assert html =~ "Other fields, such as media and rich text"

      render_click(toggle(lv, "rin_a", ctx.page.id))
      refute has_element?(lv, "#cf-ref-rin_a-#{ctx.page.id}-inline-card")
    end

    test "no card without the option", ctx do
      field!(ctx.admin, "rin_off", %{edit_inline: nil})
      post = post_with!(ctx.admin, "rin_off", [ctx.page])
      lv = open_editor(build_conn(), ctx.admin, post)

      assert has_element?(lv, "#cf-ref-rin_off-#{ctx.page.id}")
      refute has_element?(lv, "#cf-ref-rin_off-#{ctx.page.id}-inline-toggle")

      # A forged event on a field without the option opens nothing.
      lv
      |> element("#custom-field-rin_off")
      |> render_hook("inline_toggle", %{"id" => ctx.page.id})

      refute has_element?(lv, "#cf-ref-rin_off-#{ctx.page.id}-inline-card")
    end

    test "an editor who may read but not write the child has a row and no card", ctx do
      field!(ctx.admin, "rin_ro")
      post = post_with!(ctx.admin, "rin_ro", [ctx.page])
      editor = authed_user(:editor, %{editable_types: ["post"]})
      lv = open_editor(build_conn(), editor, post)

      assert has_element?(lv, "#cf-ref-rin_ro-#{ctx.page.id}")
      refute has_element?(lv, "#cf-ref-rin_ro-#{ctx.page.id}-inline-toggle")

      lv
      |> element("#custom-field-rin_ro")
      |> render_hook("inline_toggle", %{"id" => ctx.page.id})

      refute has_element?(lv, "#cf-ref-rin_ro-#{ctx.page.id}-inline-card")
    end

    test "a forged key that is not one of the field's values opens nothing", ctx do
      field!(ctx.admin, "rin_forge")
      other = CMS.create_page!(%{title: "Other", slug: "rin-#{uniq()}"}, actor: ctx.admin)
      post = post_with!(ctx.admin, "rin_forge", [ctx.page])
      lv = open_editor(build_conn(), ctx.admin, post)

      for key <- [other.id, "page:#{ctx.page.id}", "nope", ""] do
        lv |> element("#custom-field-rin_forge") |> render_hook("inline_toggle", %{"id" => key})
      end

      refute render(lv) =~ "data-inline-card"
    end

    test "a child trashed after it was connected is Unavailable with no card", ctx do
      field!(ctx.admin, "rin_trash")
      post = post_with!(ctx.admin, "rin_trash", [ctx.page])
      lv = open_editor(build_conn(), ctx.admin, post)
      assert has_element?(lv, "#cf-ref-rin_trash-#{ctx.page.id}-inline-toggle")

      CMS.destroy_page!(ctx.page, actor: ctx.admin)
      lv = open_editor(build_conn(), ctx.admin, post)

      assert render(lv) =~ "Unavailable"
      refute has_element?(lv, "#cf-ref-rin_trash-#{ctx.page.id}-inline-toggle")

      lv
      |> element("#custom-field-rin_trash")
      |> render_hook("inline_toggle", %{"id" => ctx.page.id})

      refute render(lv) =~ "data-inline-card"
    end

    test "a child trashed after the card could be opened is refused on open", ctx do
      field!(ctx.admin, "rin_late")
      post = post_with!(ctx.admin, "rin_late", [ctx.page])
      lv = open_editor(build_conn(), ctx.admin, post)

      CMS.destroy_page!(ctx.page, actor: ctx.admin)
      render_click(toggle(lv, "rin_late", ctx.page.id))

      assert render(lv) =~ "can no longer be opened here"
      refute render(lv) =~ "data-inline-card"
    end

    test "a field the actor's read grant hides is not rendered", ctx do
      field!(ctx.admin, "rin_grant")
      post = post_with!(ctx.admin, "rin_grant", [ctx.page])

      restricted = authed_user(:editor, %{field_read_grants: %{"page" => []}})
      lv = open_editor(build_conn(), restricted, post)
      render_click(toggle(lv, "rin_grant", ctx.page.id))
      html = render(card(lv, "rin_grant", ctx.page.id))
      assert html =~ "Hello kicker"
      refute html =~ "hush"
      refute html =~ "rin_secret"

      lv = open_editor(build_conn(), ctx.admin, post)
      render_click(toggle(lv, "rin_grant", ctx.page.id))
      assert render(card(lv, "rin_grant", ctx.page.id)) =~ "hush"
    end

    test "a published child shows its working copy, and says readers do not see it yet", ctx do
      field!(ctx.admin, "rin_wc")
      published = CMS.publish_page!(ctx.page, %{}, actor: ctx.admin)

      CMS.save_page_working_copy!(published, %{working_title: "Held title"}, actor: ctx.admin)

      post = post_with!(ctx.admin, "rin_wc", [ctx.page])
      lv = open_editor(build_conn(), ctx.admin, post)
      render_click(toggle(lv, "rin_wc", ctx.page.id))

      html = render(card(lv, "rin_wc", ctx.page.id))
      assert html =~ "Held title"
      assert html =~ "Showing the working copy"
      refute html =~ "Draft: readers"
    end

    test "opening an 11th card is refused", ctx do
      field!(ctx.admin, "rin_cap")

      pages =
        for n <- 1..11 do
          CMS.create_page!(%{title: "Cap #{n}", slug: "rin-#{uniq()}"}, actor: ctx.admin)
        end

      post = post_with!(ctx.admin, "rin_cap", pages)
      lv = open_editor(build_conn(), ctx.admin, post)

      for page <- pages, do: render_click(toggle(lv, "rin_cap", page.id))

      assert render(lv) |> String.split("data-inline-card") |> length() == 11
      assert render(lv) =~ "Close a record before opening another."
    end

    test "card state survives an unrelated parent edit and drops a removed row", ctx do
      field!(ctx.admin, "rin_keep")
      post = post_with!(ctx.admin, "rin_keep", [ctx.page])
      lv = open_editor(build_conn(), ctx.admin, post)
      render_click(toggle(lv, "rin_keep", ctx.page.id))

      lv
      |> element("form[phx-change=validate]")
      |> render_change(%{"form" => %{"title" => "Host renamed"}})

      assert has_element?(lv, "#cf-ref-rin_keep-#{ctx.page.id}-inline-card")

      lv
      |> element("#cf-ref-rin_keep-#{ctx.page.id} [data-ref-remove]")
      |> render_click()

      refute has_element?(lv, "#cf-ref-rin_keep-#{ctx.page.id}-inline-card")
    end
  end
end
