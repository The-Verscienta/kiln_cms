defmodule KilnCMSWeb.ContentEditorBacklinksTest do
  @moduledoc """
  The content editor reads the `ContentLink` edges (#1594): a record lists
  what links to it, asks before an unpublish that would break those links,
  and a referrer whose reference points at a trashed record says so.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "editor-backlinks-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "eb-#{System.unique_integer([:positive])}"

  setup do
    admin = authed_user(:admin)

    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: "hero",
        label: "Hero page",
        field_type: :reference,
        target_type: "page"
      },
      actor: admin
    )

    page = CMS.create_page!(%{title: "Landing", slug: slug()}, actor: admin)
    page = CMS.publish_page!(page, %{}, actor: admin)

    post =
      CMS.create_post!(
        %{title: "Spring launch", slug: slug(), custom_fields: %{"hero" => page.id}},
        actor: admin
      )

    %{admin: admin, page: page, post: post}
  end

  test "a referenced record lists its referrer and asks before unpublishing", ctx do
    {:ok, lv, _html} =
      ctx.conn |> log_in(ctx.admin) |> live(~p"/editor/content/page/#{ctx.page.id}")

    assert has_element?(lv, "#backlinks", "Linked from 1 record")

    assert has_element?(
             lv,
             ~s(#backlinks a[href="/editor/content/post/#{ctx.post.id}"]),
             "Spring launch"
           )

    assert has_element?(lv, "#backlinks", "via hero")
    assert has_element?(lv, ~s(button[phx-value-action="unpublish"][data-confirm*="links here"]))
  end

  test "an unreferenced record shows no list and no prompt", ctx do
    lonely = CMS.create_page!(%{title: "Alone", slug: slug()}, actor: ctx.admin)
    lonely = CMS.publish_page!(lonely, %{}, actor: ctx.admin)

    {:ok, lv, _html} =
      ctx.conn |> log_in(ctx.admin) |> live(~p"/editor/content/page/#{lonely.id}")

    refute has_element?(lv, "#backlinks")
    assert has_element?(lv, ~s(button[phx-value-action="unpublish"]))
    refute has_element?(lv, ~s(button[phx-value-action="unpublish"][data-confirm]))
  end

  test "a reference to a trashed record is flagged on the referrer", ctx do
    {:ok, lv, _html} =
      ctx.conn |> log_in(ctx.admin) |> live(~p"/editor/content/post/#{ctx.post.id}")

    refute has_element?(lv, "#broken-references")

    :ok = CMS.destroy_page!(ctx.page, actor: ctx.admin)

    {:ok, lv, _html} =
      ctx.conn |> log_in(ctx.admin) |> live(~p"/editor/content/post/#{ctx.post.id}")

    assert has_element?(lv, "#broken-reference-hero", "Hero page")
  end
end
