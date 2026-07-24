defmodule KilnCMSWeb.InContextEditLiveTest do
  @moduledoc """
  In-context (front-end) editing on Kiln's own rendered site (#354): an editor
  flips a page into edit mode on its rendered URL, edits text regions in place,
  and the change is written through the same Ash actions the block editor uses.

  The in-app preview browser's LiveView socket doesn't reliably connect, so the
  JS `phx-hook`s that drive the contenteditable regions can't be exercised there
  — coverage runs through LiveViewTest, which mounts the real LiveView and lets
  `render_hook/3` stand in for what the hooks push.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "incontext-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "incontext-#{System.unique_integer([:positive])}"

  # A draft page carrying one of each inline-editable block plus a read-only
  # image, each with a stable id the test targets.
  defp page_with_blocks(actor) do
    ids = %{
      heading: Ash.UUID.generate(),
      rich: Ash.UUID.generate(),
      quote: Ash.UUID.generate(),
      image: Ash.UUID.generate()
    }

    page =
      CMS.create_page!(
        %{
          title: "In-context page",
          slug: slug(),
          blocks: [
            %{"_type" => "heading", "text" => "Original heading", "id" => ids.heading},
            %{
              "_type" => "rich_text",
              "legacy_html" => "<p>Original prose.</p>",
              "id" => ids.rich
            },
            %{"_type" => "quote", "text" => "Original quote", "id" => ids.quote},
            %{"_type" => "image", "url" => "/uploads/pic.png", "id" => ids.image}
          ]
        },
        actor: actor
      )

    {page, ids}
  end

  # The stored value of a block (by id) on the reloaded record.
  defp block_value(page_id, id, field) do
    CMS.get_page!(page_id, authorize?: false).blocks
    |> Enum.map(& &1.value)
    |> Enum.find(&(&1.id == id))
    |> Map.get(field)
  end

  # The stored block ids in order.
  defp block_order(page_id) do
    CMS.get_page!(page_id, authorize?: false).blocks |> Enum.map(& &1.value.id)
  end

  describe "mount and render" do
    test "renders each block with stable ids and inline-editable regions", %{conn: conn} do
      editor = authed_user(:editor)
      {page, ids} = page_with_blocks(editor)

      {:ok, _lv, html} =
        conn |> log_in(editor) |> live(~p"/editor/site/page/#{page.slug}")

      # The edit-mode chrome and each editable region are present.
      assert html =~ "Editing in place"
      assert html =~ ~s(data-kiln-block-id="#{ids.heading}")
      assert html =~ ~s(data-kiln-block-id="#{ids.rich}")
      assert html =~ ~s(data-kiln-block-id="#{ids.quote}")

      # The heading and quote are plain contenteditable text; rich text mounts
      # the TipTap hook; the image stays read-only (no contenteditable, no id).
      assert html =~ ~r/<h2[^>]*contenteditable="true"[^>]*data-kiln-block-id="#{ids.heading}"/
      assert html =~ ~s(phx-hook="InlineText")
      assert html =~ ~s(phx-hook="InlineRichText")
      assert html =~ "/uploads/pic.png"
      refute html =~ ~s(data-kiln-block-id="#{ids.image}")
    end

    test "a columns block renders its nested children in place (#335)", %{conn: conn} do
      editor = authed_user(:editor)

      page =
        CMS.create_page!(
          %{
            title: "Columns page",
            slug: slug(),
            blocks: [
              %{
                "_type" => "columns",
                "layout" => "1-1",
                "columns" => [
                  %{"blocks" => [%{"_type" => "heading", "text" => "Nested left"}]},
                  %{"blocks" => [%{"_type" => "quote", "text" => "Nested right"}]}
                ]
              }
            ]
          },
          actor: editor
        )

      {:ok, _lv, html} =
        conn |> log_in(editor) |> live(~p"/editor/site/page/#{page.slug}")

      assert html =~ "kiln-columns"
      assert html =~ "Nested left"
      assert html =~ "Nested right"
    end

    test "unknown slug and unknown type redirect back to the editor", %{conn: conn} do
      editor = authed_user(:editor)

      assert {:error, {:live_redirect, %{to: "/editor"}}} =
               conn
               |> log_in(editor)
               |> live(~p"/editor/site/page/nope-#{System.unique_integer()}")

      page = elem(page_with_blocks(editor), 0)

      assert {:error, {:live_redirect, %{to: "/editor"}}} =
               conn |> log_in(editor) |> live(~p"/editor/site/bogustype/#{page.slug}")
    end

    test "a non-editor cannot reach the surface", %{conn: conn} do
      viewer = authed_user(:viewer)
      page = elem(page_with_blocks(authed_user(:editor)), 0)

      # The editor live_session gate bounces a non-editor to the site root.
      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> log_in(viewer) |> live(~p"/editor/site/page/#{page.slug}")
    end
  end

  describe "inline edits" do
    test "editing a heading autosaves the draft through Ash", %{conn: conn} do
      editor = authed_user(:editor)
      {page, ids} = page_with_blocks(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/site/page/#{page.slug}")

      render_hook(lv, "update_block", %{"id" => ids.heading, "value" => "Edited heading"})
      assert render(lv) =~ "Saving…"

      # Drive the debounced autosave deterministically (the JS debounce timer is
      # what schedules it in the browser).
      send(lv.pid, :autosave)
      assert render(lv) =~ "All changes saved"

      assert block_value(page.id, ids.heading, :text) == "Edited heading"
      # Other blocks and their ids are untouched.
      assert block_value(page.id, ids.quote, :text) == "Original quote"
    end

    test "editing rich text stores Portable Text from the pushed TipTap doc", %{conn: conn} do
      editor = authed_user(:editor)
      {page, ids} = page_with_blocks(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/site/page/#{page.slug}")

      tiptap = %{
        "type" => "doc",
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Rewritten prose."}]}
        ]
      }

      render_hook(lv, "update_block", %{"id" => ids.rich, "value" => tiptap})
      send(lv.pid, :autosave)
      render(lv)

      assert [%{"_type" => "block", "children" => [%{"text" => "Rewritten prose."}]}] =
               block_value(page.id, ids.rich, :body)

      assert block_value(page.id, ids.rich, :legacy_html) in [nil, ""]
    end

    test "a stale client pushing rich text as HTML still lands (legacy shim)", %{conn: conn} do
      editor = authed_user(:editor)
      {page, ids} = page_with_blocks(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/site/page/#{page.slug}")

      render_hook(lv, "update_block", %{"id" => ids.rich, "value" => "<p>Rewritten prose.</p>"})
      send(lv.pid, :autosave)
      render(lv)

      assert block_value(page.id, ids.rich, :legacy_html) =~ "Rewritten prose."
    end

    test "an edit id that isn't an inline block is ignored", %{conn: conn} do
      editor = authed_user(:editor)
      {page, ids} = page_with_blocks(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/site/page/#{page.slug}")

      # The image block is read-only; targeting it is a no-op, not a crash.
      render_hook(lv, "update_block", %{"id" => ids.image, "value" => "nope"})
      refute render(lv) =~ "Saving…"

      # An entirely unknown id is likewise ignored.
      render_hook(lv, "update_block", %{"id" => Ash.UUID.generate(), "value" => "x"})
      assert Process.alive?(lv.pid)
    end

    test "the explicit Save button persists edits", %{conn: conn} do
      editor = authed_user(:editor)
      {page, ids} = page_with_blocks(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/site/page/#{page.slug}")

      render_hook(lv, "update_block", %{"id" => ids.quote, "value" => "Saved quote"})
      html = lv |> element("#in-context-edit-bar button", "Save") |> render_click()

      assert html =~ "Saved."
      assert block_value(page.id, ids.quote, :text) == "Saved quote"
    end
  end

  describe "reordering" do
    test "the surface renders a sortable list with drag handles", %{conn: conn} do
      editor = authed_user(:editor)
      {page, ids} = page_with_blocks(editor)

      {:ok, _lv, html} = conn |> log_in(editor) |> live(~p"/editor/site/page/#{page.slug}")

      assert html =~ ~s(id="in-context-blocks")
      assert html =~ ~s(phx-hook="Sortable")
      assert html =~ ~s(data-sort-id="#{ids.heading}")
      assert html =~ "data-drag-handle"
    end

    test "a drag reorder autosaves the new block order", %{conn: conn} do
      editor = authed_user(:editor)
      {page, ids} = page_with_blocks(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/site/page/#{page.slug}")

      # Sortable pushes the new order of block ids after a drop.
      new_order = [ids.quote, ids.heading, ids.image, ids.rich]
      render_hook(lv, "reorder", %{"order" => Enum.map(new_order, &to_string/1)})
      send(lv.pid, :autosave)
      render(lv)

      assert block_order(page.id) == new_order
    end

    test "keyboard move down swaps a block with its neighbour", %{conn: conn} do
      editor = authed_user(:editor)
      {page, ids} = page_with_blocks(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/site/page/#{page.slug}")

      html = render_hook(lv, "move_block", %{"id" => ids.heading, "dir" => "down"})
      # The move is announced to screen readers.
      assert html =~ "Moved block to position 2 of 4"

      send(lv.pid, :autosave)
      render(lv)

      assert block_order(page.id) == [ids.rich, ids.heading, ids.quote, ids.image]
    end

    test "an order that isn't a permutation of the blocks is refused (no data loss)",
         %{conn: conn} do
      editor = authed_user(:editor)
      {page, ids} = page_with_blocks(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/site/page/#{page.slug}")

      original = block_order(page.id)

      # A short/garbled order (e.g. a null-id block's "" sort key) must not drop
      # blocks — it's ignored, leaving the order and every block intact.
      render_hook(lv, "reorder", %{"order" => [to_string(ids.heading), ""]})
      refute render(lv) =~ "Saving…"

      send(lv.pid, :autosave)
      render(lv)
      assert block_order(page.id) == original
    end
  end

  describe "conflict handling" do
    test "a concurrent save surfaces a conflict banner and Reload recovers", %{conn: conn} do
      editor = authed_user(:editor)
      {page, ids} = page_with_blocks(editor)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/site/page/#{page.slug}")

      render_hook(lv, "update_block", %{"id" => ids.heading, "value" => "Mine"})

      # Someone else saves first, bumping lock_version out from under this editor.
      {:ok, _} = CMS.update_page(page, %{title: "Changed elsewhere"}, actor: editor)

      html = lv |> element("#in-context-edit-bar button", "Save") |> render_click()
      assert html =~ "Someone else saved changes"
      assert html =~ ~r/id="in-context-conflict"[^>]*role="alert"/

      reloaded = lv |> element("#in-context-conflict button", "Reload latest") |> render_click()
      refute reloaded =~ "Someone else saved changes"
    end
  end
end
