defmodule KilnCMSWeb.ContentEditorUnsplashTest do
  @moduledoc """
  The content editor's own Unsplash tab inside the image picker (mirrors
  `KilnCMSWeb.MediaLive`'s tab — see `media_live_test.exs`'s "unsplash"
  describe block), except importing here has to land the new item wherever
  the picker was opened for — featured image, a brand-new image block, or a
  gallery's multi-select — instead of just refreshing a library grid.
  """
  # async: false — the setup points Storage.Local at a temp dir via the
  # global app env, same as media_live_test.exs.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  # A minimal valid 1x1 PNG.
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
         6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 250, 207, 0, 0,
         0, 7, 0, 1, 2, 254, 165, 53, 230, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

  @password "password123456"

  defp authed_user(role) do
    email = "ceunsplash-#{System.unique_integer([:positive])}@example.com"

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

  defp page(actor, attrs \\ %{}) do
    CMS.create_page!(
      Map.merge(
        %{
          title: "Unsplash spec",
          slug: "ceunsplash-#{System.unique_integer([:positive])}",
          blocks: []
        },
        attrs
      ),
      actor: actor
    )
  end

  defp unsplash_result(id) do
    %{
      "id" => id,
      "width" => 4000,
      "height" => 3000,
      "alt_description" => "dried herbs on a table",
      "urls" => %{"small" => "https://images.unsplash.com/photo-#{id}?w=400"},
      "links" => %{
        "html" => "https://unsplash.com/photos/#{id}",
        "download_location" => "https://api.unsplash.com/photos/#{id}/download"
      },
      "user" => %{
        "name" => "Jane Lens",
        "links" => %{"html" => "https://unsplash.com/@janelens"}
      }
    }
  end

  # Page 2 returns a DIFFERENT photo id than page 1 — the real API paginates
  # distinct results, and reusing the same id would render two elements with
  # the same DOM id once "Load more" appends the second page.
  defp stub_unsplash(png) do
    Req.Test.stub(KilnCMS.Unsplash, fn conn ->
      case conn.request_path do
        "/search/photos" ->
          conn = Plug.Conn.fetch_query_params(conn)
          id = photo_id_for_page(conn.query_params["page"])
          Req.Test.json(conn, %{"total_pages" => 2, "results" => [unsplash_result(id)]})

        "/photos/abc123/download" ->
          Req.Test.json(conn, %{"url" => "https://images.unsplash.com/file-abc123"})

        "/photos/def456/download" ->
          Req.Test.json(conn, %{"url" => "https://images.unsplash.com/file-def456"})

        "/file-abc123" ->
          conn
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.send_resp(200, png)

        "/file-def456" ->
          conn
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.send_resp(200, png)
      end
    end)
  end

  defp photo_id_for_page("2"), do: "def456"
  defp photo_id_for_page(_), do: "abc123"

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_ceunsplash_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:kiln_cms, KilnCMS.Storage.Local, root: root, base_url: "/uploads")

    previous = Application.get_env(:kiln_cms, :unsplash, [])
    Application.put_env(:kiln_cms, :unsplash, Keyword.put(previous, :access_key, "test-key"))

    on_exit(fn ->
      File.rm_rf!(root)
      Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
      Application.put_env(:kiln_cms, :unsplash, previous)
    end)

    :ok
  end

  test "the tab is hidden while no access key is configured", %{conn: conn} do
    previous = Application.get_env(:kiln_cms, :unsplash, [])
    Application.put_env(:kiln_cms, :unsplash, Keyword.delete(previous, :access_key))
    on_exit(fn -> Application.put_env(:kiln_cms, :unsplash, previous) end)

    editor = authed_user(:editor)
    pg = page(editor)
    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{pg.id}")

    render_click(lv, "open_featured_picker", %{})
    refute render(lv) =~ ~s(phx-click="picker_tab")
  end

  test "the tab is visible once an access key is configured", %{conn: conn} do
    editor = authed_user(:editor)
    pg = page(editor)
    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{pg.id}")

    render_click(lv, "open_featured_picker", %{})
    assert render(lv) =~ ~s(phx-click="picker_tab")
  end

  test "searching lists photos with photographer attribution", %{conn: conn} do
    stub_unsplash(@png)
    editor = authed_user(:editor)
    pg = page(editor)
    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{pg.id}")

    render_click(lv, "open_featured_picker", %{})
    render_click(lv, "picker_tab", %{"tab" => "unsplash"})
    lv |> form("#editor-unsplash-search", %{q: "herbs"}) |> render_submit()

    html = render_async(lv, 2_000)
    assert html =~ "editor-unsplash-abc123"
    assert html =~ "dried herbs on a table"
    assert html =~ "Jane Lens"
  end

  test "load more paginates results", %{conn: conn} do
    stub_unsplash(@png)
    editor = authed_user(:editor)
    pg = page(editor)
    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{pg.id}")

    render_click(lv, "open_featured_picker", %{})
    render_click(lv, "picker_tab", %{"tab" => "unsplash"})
    lv |> form("#editor-unsplash-search", %{q: "herbs"}) |> render_submit()
    render_async(lv, 2_000)

    assert render(lv) =~ "Load more"
    render_click(lv, "unsplash_load_more", %{})
    html = render_async(lv, 2_000)

    assert html =~ "editor-unsplash-abc123"
    assert html =~ "editor-unsplash-def456"
  end

  test "importing on the featured-image context sets featured_image_id", %{conn: conn} do
    stub_unsplash(@png)
    editor = authed_user(:editor)
    pg = page(editor)
    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{pg.id}")

    render_click(lv, "open_featured_picker", %{})
    render_click(lv, "picker_tab", %{"tab" => "unsplash"})
    lv |> form("#editor-unsplash-search", %{q: "herbs"}) |> render_submit()
    render_async(lv, 2_000)

    render_click(lv, "unsplash_import", %{"id" => "abc123"})
    render_async(lv, 5_000)

    lv |> form("#page-editor") |> render_submit()

    assert [item] = CMS.list_media_items!(actor: editor)
    assert item.filename == "unsplash-abc123.png"
    assert CMS.get_page!(pg.id, authorize?: false).featured_image_id == item.id

    # The picker closes after a single-select import, same as `pick_image`.
    refute render(lv) =~ "image-picker-dialog"
  end

  test "importing on a new-image-block context inserts a block", %{conn: conn} do
    stub_unsplash(@png)
    editor = authed_user(:editor)
    pg = page(editor)
    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{pg.id}")

    render_click(lv, "open_media_browser", %{})
    render_click(lv, "picker_tab", %{"tab" => "unsplash"})
    lv |> form("#editor-unsplash-search", %{q: "herbs"}) |> render_submit()
    render_async(lv, 2_000)

    render_click(lv, "unsplash_import", %{"id" => "abc123"})
    render_async(lv, 5_000)

    lv |> form("#page-editor") |> render_submit()

    assert [item] = CMS.list_media_items!(actor: editor)
    [block] = CMS.get_page!(pg.id, authorize?: false).blocks
    assert block.value.media_id == item.id
    assert block.value.url == item.url
  end

  test "importing in a gallery context appends to the selection without closing the drawer", %{
    conn: conn
  } do
    stub_unsplash(@png)
    editor = authed_user(:editor)

    pg =
      page(editor, %{
        blocks: [%{"_type" => "gallery", "id" => Ash.UUID.generate(), "images" => []}]
      })

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{pg.id}")

    bid = pg.blocks |> hd() |> Map.fetch!(:value) |> Map.fetch!(:id)

    render_click(lv, "open_gallery_picker", %{"bid" => bid})
    render_click(lv, "picker_tab", %{"tab" => "unsplash"})
    lv |> form("#editor-unsplash-search", %{q: "herbs"}) |> render_submit()
    render_async(lv, 2_000)

    render_click(lv, "unsplash_import", %{"id" => "abc123"})
    render_async(lv, 5_000)

    # Still open, on the Unsplash tab, one image selected.
    html = render(lv)
    assert html =~ "image-picker-dialog"
    assert html =~ "1 image selected"

    render_click(lv, "add_picked_images", %{"bid" => bid})
    lv |> form("#page-editor") |> render_submit()

    assert [item] = CMS.list_media_items!(actor: editor)
    [block] = CMS.get_page!(pg.id, authorize?: false).blocks
    assert Enum.map(block.value.images, & &1["media_id"]) == [item.id]
  end

  test "a failed import flashes an error and leaves the picker open", %{conn: conn} do
    Req.Test.stub(KilnCMS.Unsplash, fn conn ->
      case conn.request_path do
        "/search/photos" ->
          Req.Test.json(conn, %{
            "total_pages" => 1,
            "results" => [
              %{
                "id" => "abc123",
                "urls" => %{"small" => "https://images.unsplash.com/photo-abc123?w=400"},
                "links" => %{
                  "download_location" => "https://api.unsplash.com/photos/abc123/download"
                },
                "user" => %{"name" => "Jane Lens"}
              }
            ]
          })

        _ ->
          Plug.Conn.send_resp(conn, 500, "boom")
      end
    end)

    editor = authed_user(:editor)
    pg = page(editor)
    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{pg.id}")

    render_click(lv, "open_featured_picker", %{})
    render_click(lv, "picker_tab", %{"tab" => "unsplash"})
    lv |> form("#editor-unsplash-search", %{q: "herbs"}) |> render_submit()
    render_async(lv, 2_000)

    render_click(lv, "unsplash_import", %{"id" => "abc123"})
    html = render_async(lv, 5_000)

    assert html =~ "Couldn&#39;t import that photo from Unsplash."
    assert html =~ "image-picker-dialog"
    assert html =~ "editor-unsplash-abc123"
    assert CMS.list_media_items!(authorize?: false) == []
  end
end
