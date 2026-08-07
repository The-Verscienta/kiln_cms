defmodule KilnCMSWeb.DuplicateContentTest do
  @moduledoc """
  The Duplicate action's two editor surfaces (#471): the content list's row
  button and the content editor's header button. Both clone the record into a
  new draft and land the editor in it; the clone mechanics themselves are
  covered by `KilnCMS.CMS.DuplicationTest`.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  require Ash.Query

  @password "password123456"

  defp authed_user(role) do
    email = "dupui-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "dupui-#{System.unique_integer([:positive])}"

  defp copy_of(source) do
    KilnCMS.CMS.Page
    |> Ash.Query.filter(title == ^(source.title <> " (copy)"))
    |> Ash.read_one!(authorize?: false)
  end

  test "the content list's Duplicate button clones the row and opens the copy", %{conn: conn} do
    editor = authed_user(:editor)

    source =
      CMS.create_page!(
        %{
          title: "Launch checklist",
          slug: slug(),
          seo_title: "Checklist",
          blocks: [%{"_type" => "heading", "text" => "Step one"}]
        },
        actor: editor
      )

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")

    assert {:error, {:live_redirect, %{to: to}}} =
             lv
             |> element("button[phx-click='duplicate'][phx-value-id='#{source.id}']")
             |> render_click()

    copy = copy_of(source)

    assert to == "/editor/content/page/#{copy.id}"
    assert copy.state == :draft
    assert copy.seo_title == "Checklist"
    assert copy.slug != source.slug
    assert [%Ash.Union{value: %{text: "Step one"}}] = copy.blocks
  end

  test "the content editor's Duplicate button clones the record and opens the copy", %{conn: conn} do
    editor = authed_user(:editor)
    source = CMS.create_page!(%{title: "Recipe", slug: slug()}, actor: editor)

    {:ok, lv, _html} =
      conn |> log_in(editor) |> live(~p"/editor/content/page/#{source.id}")

    assert {:error, {:live_redirect, %{to: to}}} =
             lv |> element("button[phx-click='duplicate']") |> render_click()

    copy = copy_of(source)

    assert to == "/editor/content/page/#{copy.id}"
    assert copy.id != source.id
    assert copy.state == :draft
  end

  test "a refused duplicate flashes instead of crashing the list", %{conn: conn} do
    admin = authed_user(:admin)
    source = CMS.create_page!(%{title: "Off limits", slug: slug()}, actor: admin)

    scoped = authed_user(:editor)

    {:ok, scoped} =
      KilnCMS.Accounts.manage_user_access(scoped, %{editable_types: ["post"]}, actor: admin)

    {:ok, lv, _html} = conn |> log_in(scoped) |> live(~p"/editor")

    html =
      lv
      |> element("button[phx-click='duplicate'][phx-value-id='#{source.id}']")
      |> render_click()

    assert html =~ "Couldn&#39;t duplicate that content."
  end

  # `kind` and `id` ride on the clicked row, so they are client input. A crafted
  # pair must flash, not take the LiveView down with it.
  test "a crafted kind or id flashes instead of crashing the list", %{conn: conn} do
    editor = authed_user(:editor)
    _source = CMS.create_page!(%{title: "Anything", slug: slug()}, actor: editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor")

    for params <- [
          %{"kind" => "not_a_type", "id" => Ash.UUID.generate()},
          %{"kind" => "page", "id" => Ash.UUID.generate()},
          %{"kind" => "page", "id" => "not-a-uuid"}
        ] do
      assert render_click(lv, "duplicate", params) =~ "Couldn&#39;t duplicate that content."
    end
  end
end
