defmodule KilnCMSWeb.ContentEditorReorderPersistsTest do
  @moduledoc """
  A reorder survives the next save (#2132).

  The usability round moved an image between a heading and a rich-text block;
  the move rendered and was announced, then the next autosave or Save put the
  blocks back.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.TypedFixtures
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Post

  @moduletag :capture_log
  @password "password123456"

  defp authed_user(role) do
    email = "reorder-#{System.unique_integer([:positive])}@example.com"

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

  defp open_editor(conn, post) do
    {:ok, lv, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(authed_user(:editor))
      |> live(~p"/editor/content/post/#{post.id}")

    lv
  end

  defp draft_post(blocks) do
    Ash.Seed.seed!(Post, %{
      title: "Reorder post",
      slug: "reorder-#{System.unique_integer([:positive])}",
      state: :draft,
      blocks: blocks
    })
  end

  defp saved_types(post),
    do: Enum.map(CMS.get_post!(post.id, authorize?: false).blocks, &block_type/1)

  defp block_type(%Ash.Union{type: type}), do: to_string(type)

  defp block_type(%{__struct__: mod}),
    do: mod |> Module.split() |> List.last() |> Macro.underscore()

  defp ids_by_type(lv) do
    ~r/data-block-id="([^"]+)"[^>]*data-block-type="([^"]+)"/
    |> Regex.scan(render(lv))
    |> Map.new(fn [_, id, type] -> {type, id} end)
  end

  defp rendered_types(lv) do
    ~r/data-block-id="[^"]+"[^>]*data-block-type="([^"]+)"/
    |> Regex.scan(render(lv))
    |> Enum.map(fn [_, type] -> type end)
  end

  defp seeded_post do
    draft_post(
      typed_blocks([
        %{type: :heading, content: "Title", order: 0},
        %{type: :rich_text, content: "<p>Body</p>", order: 1},
        %{type: :image, content: "/uploads/pic.jpg", order: 2}
      ])
    )
  end

  test "a moved block keeps its place through autosave", %{conn: conn} do
    post = seeded_post()
    lv = open_editor(conn, post)

    render_click(lv, "move_block", %{"bid" => ids_by_type(lv)["image"], "dir" => "up"})
    send(lv.pid, :autosave)
    render(lv)

    assert saved_types(post) == ["heading", "image", "rich_text"]
  end

  test "a moved block keeps its place through an explicit Save", %{conn: conn} do
    post = seeded_post()
    lv = open_editor(conn, post)

    render_click(lv, "move_block", %{"bid" => ids_by_type(lv)["image"], "dir" => "up"})
    lv |> form("#post-editor") |> render_submit()

    assert saved_types(post) == ["heading", "image", "rich_text"]
  end

  test "a dragged order keeps its place through autosave", %{conn: conn} do
    post = seeded_post()
    lv = open_editor(conn, post)

    render_hook(lv, "reorder", %{"order" => ["0", "2", "1"]})
    send(lv.pid, :autosave)
    render(lv)

    assert saved_types(post) == ["heading", "image", "rich_text"]
  end

  # The form is rebuilt from the row after every autosave, so a reverted
  # autosave used to undo the move on screen and hand the old order to Save.
  test "Save after an autosave keeps the moved order", %{conn: conn} do
    post = seeded_post()
    lv = open_editor(conn, post)

    render_click(lv, "move_block", %{"bid" => ids_by_type(lv)["image"], "dir" => "up"})
    send(lv.pid, :autosave)
    assert rendered_types(lv) == ["heading", "image", "rich_text"]

    lv |> form("#post-editor") |> render_submit()

    assert saved_types(post) == ["heading", "image", "rich_text"]
  end
end
