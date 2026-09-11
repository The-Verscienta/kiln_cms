defmodule KilnCMSWeb.ContentEditorBodyUploadTest do
  @moduledoc """
  Pictures pasted or dropped on a rich-text block (the texttile pattern, adapted
  to the block editor): the `BodyImageUploader` hook names the anchor block and
  feeds the files to a hidden `live_file_input`; each finished entry goes
  through `Ingest` and lands as an image block right after that anchor, with a
  server-rendered placeholder standing in the list while it travels.

  Alongside, the two behaviours that ride the same seams: a workflow button
  saves a draft's queued edits before it transitions (so Publish publishes what
  is on the screen), and the save line says only what it knows.
  """
  # async: false — the setup points Storage.Local at a temp dir via the global
  # app env, same as media_live_test.exs.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import KilnCMS.TipTapFixtures

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  # A minimal valid 1x1 PNG.
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
         6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 250, 207, 0, 0,
         0, 7, 0, 1, 2, 254, 165, 53, 230, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

  @password "password123456"

  defp authed_user(role, grants \\ %{}) do
    email = "cebody-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        grants
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

  # Two prose blocks, so "after the first" is distinguishable from "at the end".
  defp page(actor, attrs \\ %{}) do
    CMS.create_page!(
      Map.merge(
        %{
          title: "Body upload spec",
          slug: "cebody-#{System.unique_integer([:positive])}",
          blocks: [
            %{"_type" => "rich_text", "id" => Ash.UUID.generate(), "legacy_html" => "<p>one</p>"},
            %{"_type" => "rich_text", "id" => Ash.UUID.generate(), "legacy_html" => "<p>two</p>"}
          ]
        },
        attrs
      ),
      actor: actor
    )
  end

  defp block_id(page, index),
    do: page.blocks |> Enum.at(index) |> Map.fetch!(:value) |> Map.fetch!(:id)

  defp block_types(page_id) do
    CMS.get_page!(page_id, authorize?: false).blocks
    |> Enum.map(&{&1.type, &1.value})
  end

  defp open(conn, user, page) do
    {:ok, lv, html} = conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")
    {lv, html}
  end

  defp png_input(lv, name) do
    file_input(lv, "#page-editor", :body_images, [
      %{name: name, content: @png, type: "image/png"}
    ])
  end

  setup do
    root = Path.join(System.tmp_dir!(), "kiln_cebody_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:kiln_cms, KilnCMS.Storage.Local, root: root, base_url: "/uploads")

    on_exit(fn ->
      File.rm_rf!(root)
      Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
    end)

    :ok
  end

  describe "paste / drop into a rich-text block" do
    test "a dropped image stands in the list while it uploads, then becomes an image block after its anchor",
         %{conn: conn} do
      admin = authed_user(:admin)
      pg = page(admin)
      first = block_id(pg, 0)
      {lv, _html} = open(conn, admin, pg)

      # The hook names the anchor before the bytes go (same channel, in order).
      render_hook(lv, "body_images_anchor", %{"after" => first, "names" => ["pixel.png"]})

      # Part-way up: the placeholder says which file and how far, with a Cancel.
      input = png_input(lv, "pixel.png")
      html = render_upload(input, "pixel.png", 40)
      assert html =~ "Uploading pixel.png… 40%"
      assert html =~ "Cancel"
      # Nothing has landed in the form yet.
      assert [{:rich_text, _}, {:rich_text, _}] = block_types(pg.id)

      # The rest of the bytes: the progress callback consumes the entry, the
      # file goes through Ingest, and the block appears right after the anchor.
      html = render_upload(input, "pixel.png", 60)
      refute html =~ "Uploading pixel.png"

      send(lv.pid, :autosave)
      _ = render(lv)

      assert [{:rich_text, _}, {:image, image}, {:rich_text, _}] = block_types(pg.id)
      assert image.url =~ "/uploads/"
      assert image.media_id

      {:ok, item} = CMS.get_media_item(image.media_id, authorize?: false)
      assert item.filename == "pixel.png"
    end

    test "without an anchor the block lands at the end", %{conn: conn} do
      admin = authed_user(:admin)
      pg = page(admin)
      {lv, _html} = open(conn, admin, pg)

      render_hook(lv, "body_images_anchor", %{"after" => nil, "names" => ["tail.png"]})
      lv |> png_input("tail.png") |> render_upload("tail.png")

      send(lv.pid, :autosave)
      _ = render(lv)

      assert [{:rich_text, _}, {:rich_text, _}, {:image, _}] = block_types(pg.id)
    end

    test "two files pasted together keep their order", %{conn: conn} do
      admin = authed_user(:admin)
      pg = page(admin)
      first = block_id(pg, 0)
      {lv, _html} = open(conn, admin, pg)

      render_hook(lv, "body_images_anchor", %{"after" => first, "names" => ["a.png", "b.png"]})

      # Two clients rather than one with two entries: the test upload client
      # stops when the server consumes its first finished entry (auto_upload +
      # progress), which is exactly what happens here.
      lv |> png_input("a.png") |> render_upload("a.png")
      lv |> png_input("b.png") |> render_upload("b.png")

      send(lv.pid, :autosave)
      _ = render(lv)

      assert [{:rich_text, _}, {:image, a}, {:image, b}, {:rich_text, _}] = block_types(pg.id)
      {:ok, item_a} = CMS.get_media_item(a.media_id, authorize?: false)
      {:ok, item_b} = CMS.get_media_item(b.media_id, authorize?: false)
      assert {item_a.filename, item_b.filename} == {"a.png", "b.png"}
    end

    test "an oversized file is refused before it travels, and the placeholder says so",
         %{conn: conn} do
      admin = authed_user(:admin)
      pg = page(admin)
      first = block_id(pg, 0)
      {lv, _html} = open(conn, admin, pg)

      render_hook(lv, "body_images_anchor", %{"after" => first, "names" => ["huge.png"]})

      input =
        file_input(lv, "#page-editor", :body_images, [
          %{name: "huge.png", content: :binary.copy(<<0>>, 10_000_001), type: "image/png"}
        ])

      # The client-side check refuses the entry; render_upload reports the error.
      assert {:error, [[_ref, :too_large]]} = render_upload(input, "huge.png")

      html = render(lv)
      assert html =~ "huge.png couldn&#39;t be uploaded: too large (max 10 MB)"
      assert html =~ "Dismiss"

      # Dismiss takes the placeholder (and its anchor) away.
      [ref] =
        html
        |> Floki.parse_document!()
        |> Floki.attribute("button[phx-click='cancel_body_image']", "phx-value-ref")

      html = render_click(lv, "cancel_body_image", %{"ref" => ref})
      refute html =~ "huge.png"
      assert [{:rich_text, _}, {:rich_text, _}] = block_types(pg.id)
    end

    test "the upload's own change event does not mark the draft dirty", %{conn: conn} do
      admin = authed_user(:admin)
      pg = page(admin)
      {lv, _html} = open(conn, admin, pg)

      html = render_hook(lv, "validate", %{"_target" => ["body_images"], "form" => %{}})
      assert html =~ ~s(data-state="saved")
      assert html =~ ~s(data-dirty="false")
    end

    test "a reader who may not write this content has the file refused", %{conn: conn} do
      # An editor scoped to author only "post" can open a page but not write it.
      reader = authed_user(:editor, %{editable_types: ["post"], readable_types: []})
      pg = page(authed_user(:admin))
      {lv, _html} = open(conn, reader, pg)

      render_hook(lv, "body_images_anchor", %{"after" => block_id(pg, 0), "names" => ["x.png"]})
      lv |> png_input("x.png") |> render_upload("x.png")

      html = render(lv)
      assert html =~ "You don&#39;t have permission to add images here."
      assert [{:rich_text, _}, {:rich_text, _}] = block_types(pg.id)
      assert CMS.list_media_items!(authorize?: false) == []
    end
  end

  describe "a workflow button settles the draft first" do
    test "Publish carries the body a rich-text block had just flushed", %{conn: conn} do
      admin = authed_user(:admin)
      pg = page(admin)
      first = block_id(pg, 0)
      {lv, _html} = open(conn, admin, pg)

      # The mousedown flush: the body arrives, the draft is pending autosave.
      html =
        render_hook(lv, "rich_text_body", %{
          "id" => first,
          "idx" => "0",
          "doc" => doc([para("flushed just before Publish")])
        })

      assert html =~ ~s(data-state="pending")

      # The click, with the debounce timer still pending — nothing fired it.
      html = render_click(lv, "workflow", %{"action" => "publish"})
      assert html =~ "Updated to"

      published = CMS.get_page!(pg.id, authorize?: false)
      assert published.state == :published

      assert [%{"children" => [%{"text" => "flushed just before Publish"}]}] =
               hd(published.blocks).value.body
    end

    test "a non-draft with unsaved edits is not transitioned, and is told why", %{conn: conn} do
      admin = authed_user(:admin)
      pg = page(admin, %{title: "In review"})
      {:ok, pg} = CMS.submit_page_for_review(pg, %{}, actor: admin)
      assert pg.state == :in_review

      {lv, _html} = open(conn, admin, pg)
      html = lv |> form("#page-editor", form: %{title: "Edited in review"}) |> render_change()
      assert html =~ ~s(data-state="unsaved")

      html = render_click(lv, "workflow", %{"action" => "publish"})
      assert html =~ "Save your changes before changing this content&#39;s state."

      assert CMS.get_page!(pg.id, authorize?: false).state == :in_review
      assert CMS.get_page!(pg.id, authorize?: false).title == "In review"
    end

    test "Save and the workflow buttons carry the flush contract", %{conn: conn} do
      admin = authed_user(:admin)
      {_lv, html} = open(conn, admin, page(admin))

      buttons =
        html
        |> Floki.parse_document!()
        |> Floki.find("[data-flush-body]")

      assert Enum.any?(buttons, &(Floki.attribute(&1, "type") == ["submit"]))
      assert Enum.any?(buttons, &(Floki.attribute(&1, "phx-value-action") == ["publish"]))
    end
  end

  describe "the save line" do
    test "carries the record's last write and only ever flips to pending while typing",
         %{conn: conn} do
      admin = authed_user(:admin)
      pg = page(admin)
      {lv, html} = open(conn, admin, pg)

      at = DateTime.to_unix(pg.updated_at, :millisecond)
      assert html =~ ~s(data-state="saved")
      assert html =~ ~s(data-at="#{at}")

      # Typing queues an autosave; the line does not claim a request is in flight.
      html = lv |> form("#page-editor", form: %{title: "Typed"}) |> render_change()
      assert html =~ ~s(data-state="pending")
      refute html =~ ~r/>\s*Saving…/

      # The flush lands: saved, and the stamp moved to the new write.
      send(lv.pid, :autosave)
      html = render(lv)
      assert html =~ ~s(data-state="saved")
      new_at = DateTime.to_unix(CMS.get_page!(pg.id, authorize?: false).updated_at, :millisecond)
      assert html =~ ~s(data-at="#{new_at}")
      assert new_at > at
    end

    test "a block that reloaded a co-editor's save after a dropped line says so once",
         %{conn: conn} do
      admin = authed_user(:admin)
      {lv, _html} = open(conn, admin, page(admin))

      html = render_hook(lv, "rich_text_superseded", %{})
      assert html =~ "saved elsewhere while you were offline"
    end
  end
end
