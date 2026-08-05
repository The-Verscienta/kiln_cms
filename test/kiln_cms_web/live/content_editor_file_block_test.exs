defmodule KilnCMSWeb.ContentEditorFileBlockTest do
  @moduledoc """
  The `:file` block's editor integration (#481): the palette inserts an
  empty block (the generic `add_block` path every block type already gets
  for free), then a dedicated document-only picker fills it in — denormalizing
  filename/content_type/byte_size onto the block server-side rather than
  trusting whatever the click payload claims.
  """
  # async: false — the setup points Storage.Local at a temp dir via the
  # global app env, same as media_live_test.exs.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "filebk-#{System.unique_integer([:positive])}@example.com"

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
          title: "File block spec",
          slug: "filebk-#{System.unique_integer([:positive])}",
          blocks: [%{"_type" => "file"}]
        },
        attrs
      ),
      actor: actor
    )
  end

  defp block_id(page, index \\ 0),
    do: page.blocks |> Enum.at(index) |> Map.fetch!(:value) |> Map.fetch!(:id)

  defp document!(actor, attrs \\ %{}) do
    key = KilnCMS.Storage.generate_key("brochure.pdf")
    src = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}")
    File.write!(src, "%PDF-1.7\nfake pdf")
    {:ok, ^key} = KilnCMS.Storage.store(key, src)

    CMS.create_media_item!(
      Map.merge(
        %{
          filename: "brochure.pdf",
          content_type: "application/pdf",
          byte_size: 4096,
          storage_key: key,
          url: KilnCMS.Storage.url(key)
        },
        attrs
      ),
      actor: actor
    )
  end

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_fb_#{System.unique_integer([:positive])}")

    private_root =
      Path.join(System.tmp_dir!(), "kiln_fb_priv_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.mkdir_p!(private_root)

    Application.put_env(:kiln_cms, KilnCMS.Storage.Local,
      root: root,
      private_root: private_root,
      base_url: "/uploads"
    )

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(private_root)
      Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
    end)

    :ok
  end

  test "the palette can insert a file block", %{conn: conn} do
    editor = authed_user(:editor)
    blank = page(editor, %{blocks: []})

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{blank.id}")

    render_click(lv, "add_block", %{"type" => "file"})

    assert render(lv) =~ "Choose from library"
  end

  test "the file picker lists only documents, not images", %{conn: conn} do
    editor = authed_user(:editor)
    _doc = document!(editor)

    _image =
      CMS.create_media_item!(
        %{
          filename: "photo.png",
          content_type: "image/png",
          width: 10,
          height: 10,
          url: "/uploads/x"
        },
        actor: editor
      )

    pg = page(editor)
    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{pg.id}")

    render_click(lv, "open_file_picker", %{"bid" => block_id(pg)})
    html = render(lv)

    assert html =~ "brochure.pdf"
    refute html =~ "photo.png"
  end

  test "a gated document shows a Gated badge in the picker", %{conn: conn} do
    editor = authed_user(:editor)
    doc = document!(editor)
    {:ok, gated} = CMS.update_media_item(doc, %{audience: :member}, actor: editor)

    pg = page(editor)
    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{pg.id}")

    render_click(lv, "open_file_picker", %{"bid" => block_id(pg)})
    html = render(lv)

    assert html =~ gated.filename
    assert html =~ "Gated"
  end

  test "picking a document fills the block, denormalizing filename/content_type/byte_size server-side",
       %{conn: conn} do
    editor = authed_user(:editor)
    doc = document!(editor)
    pg = page(editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{pg.id}")

    render_click(lv, "open_file_picker", %{"bid" => block_id(pg)})
    render_click(lv, "pick_file", %{"id" => doc.id})

    lv |> form("#page-editor") |> render_submit()

    [block] = CMS.get_page!(pg.id, authorize?: false).blocks
    filled = block.value

    assert filled.media_id == doc.id
    assert filled.filename == "brochure.pdf"
    assert filled.content_type == "application/pdf"
    assert filled.byte_size == 4096
  end

  test "picking a document found only via search (created after mount) still fills the block", %{
    conn: conn
  } do
    editor = authed_user(:editor)
    pg = page(editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{pg.id}")

    # Created AFTER the LiveView mounted @file_media — reachable only through
    # a live search (@picker_files), never the mount-time snapshot. A picker
    # that only ever looked in @file_media would silently no-op here.
    doc = document!(editor, %{filename: "late-arrival.pdf"})

    render_click(lv, "open_file_picker", %{"bid" => block_id(pg)})
    render_click(lv, "search_file_media", %{"q" => "late-arrival"})
    render_click(lv, "pick_file", %{"id" => doc.id})

    lv |> form("#page-editor") |> render_submit()

    [block] = CMS.get_page!(pg.id, authorize?: false).blocks
    assert block.value.media_id == doc.id
    assert block.value.filename == "late-arrival.pdf"
  end

  test "the picker closes after picking, leaving no stray state", %{conn: conn} do
    editor = authed_user(:editor)
    doc = document!(editor)
    pg = page(editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{pg.id}")

    render_click(lv, "open_file_picker", %{"bid" => block_id(pg)})
    assert render(lv) =~ "file-picker-dialog"

    render_click(lv, "pick_file", %{"id" => doc.id})
    refute render(lv) =~ "file-picker-dialog"
  end

  test "an unknown open_file_picker id is a no-op, not a crash", %{conn: conn} do
    editor = authed_user(:editor)
    pg = page(editor)

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{pg.id}")

    render_click(lv, "open_file_picker", %{"bid" => ""})
    assert render(lv) =~ "File block spec"
  end
end
