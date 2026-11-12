defmodule KilnCMSWeb.ContentEditorPickerUploadTest do
  @moduledoc """
  Uploading straight from the image picker drawer. Before this, the drawer
  could only choose from what was already in the library (or import from
  Unsplash), so setting a featured image from a new photo meant leaving for
  `/media`, uploading, coming back and finding it again.

  A finished upload lands on whatever the drawer was opened for — the same
  routing as a library pick or an Unsplash import — and in a gallery joins the
  selection instead of closing the drawer.
  """
  # async: false — the setup points Storage.Local at a temp dir via the global
  # app env, same as content_editor_body_upload_test.exs.
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
    email = "cepick-#{System.unique_integer([:positive])}@example.com"

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

  defp open(conn, user, page) do
    {:ok, lv, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(~p"/editor/content/page/#{page.id}")

    lv
  end

  defp page(actor, attrs \\ %{}) do
    CMS.create_page!(
      Map.merge(
        %{title: "Picker upload spec", slug: "cepick-#{System.unique_integer([:positive])}"},
        attrs
      ),
      actor: actor
    )
  end

  defp picker_input(lv, files) do
    file_input(
      lv,
      "#image-picker-upload",
      :picker_images,
      Enum.map(files, fn {name, content} -> %{name: name, content: content, type: "image/png"} end)
    )
  end

  defp save(lv), do: lv |> form("#page-editor") |> render_submit()

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_cepick_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:kiln_cms, KilnCMS.Storage.Local, root: root, base_url: "/uploads")

    on_exit(fn ->
      File.rm_rf!(root)
      Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
    end)

    :ok
  end

  test "the featured image drawer offers an upload, and an uploaded file becomes the featured image",
       %{conn: conn} do
    editor = authed_user(:editor)
    pg = page(editor)
    lv = open(conn, editor, pg)

    render_click(lv, "open_featured_picker", %{})
    html = render(lv)
    assert html =~ ~s(id="image-picker-upload")
    assert html =~ "Upload an image"

    input = picker_input(lv, [{"hero.png", @png}])
    assert render_upload(input, "hero.png", 40) =~ "Uploading hero.png… 40%"

    # The rest of the bytes: Ingest stores it, and the single-select drawer
    # closes on the pick, the same as choosing from the library.
    html = render_upload(input, "hero.png", 60)
    refute html =~ "image-picker-dialog"

    save(lv)

    assert [item] = CMS.list_media_items!(actor: editor)
    assert item.filename == "hero.png"
    assert CMS.get_page!(pg.id, authorize?: false).featured_image_id == item.id
  end

  test "an upload into a gallery joins the selection and keeps the drawer open", %{conn: conn} do
    editor = authed_user(:editor)

    pg =
      page(editor, %{
        blocks: [%{"_type" => "gallery", "id" => Ash.UUID.generate(), "images" => []}]
      })

    bid = pg.blocks |> hd() |> Map.fetch!(:value) |> Map.fetch!(:id)
    lv = open(conn, editor, pg)

    render_click(lv, "open_gallery_picker", %{"bid" => bid})
    assert render(lv) =~ "Upload images"

    input = picker_input(lv, [{"one.png", @png}, {"two.png", @png}])
    render_upload(input, "one.png")
    html = render_upload(input, "two.png")

    assert html =~ "image-picker-dialog"
    assert html =~ "2 images selected"

    render_click(lv, "add_picked_images", %{"bid" => bid})
    save(lv)

    items = CMS.list_media_items!(actor: editor)
    by_name = Map.new(items, &{&1.filename, &1.id})
    [block] = CMS.get_page!(pg.id, authorize?: false).blocks

    assert Enum.map(block.value.images, & &1["media_id"]) ==
             [by_name["one.png"], by_name["two.png"]]
  end

  test "a file that is not an image is refused and stored nowhere", %{conn: conn} do
    editor = authed_user(:editor)
    pg = page(editor)
    lv = open(conn, editor, pg)

    render_click(lv, "open_featured_picker", %{})

    # Named `.png` so it passes the client-side `accept`; the server sniffs it.
    input = picker_input(lv, [{"notes.png", "%PDF-1.4 not really an image"}])
    html = render_upload(input, "notes.png")

    assert html =~ "Couldn&#39;t upload notes.png: unsupported file format"
    # The drawer stays open so another file can be tried.
    assert html =~ "image-picker-dialog"
    assert CMS.list_media_items!(actor: editor) == []
    assert CMS.get_page!(pg.id, authorize?: false).featured_image_id == nil
  end

  test "closing the drawer abandons an upload still in flight", %{conn: conn} do
    editor = authed_user(:editor)
    pg = page(editor)
    lv = open(conn, editor, pg)

    render_click(lv, "open_featured_picker", %{})
    input = picker_input(lv, [{"late.png", @png}])
    render_upload(input, "late.png", 40)

    render_click(lv, "close_picker", %{})
    refute render(lv) =~ "late.png"

    assert CMS.list_media_items!(actor: editor) == []
    assert CMS.get_page!(pg.id, authorize?: false).featured_image_id == nil
  end
end
