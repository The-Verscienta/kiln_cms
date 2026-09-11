defmodule KilnCMSWeb.ContentEditorMoveBlocksTest do
  @moduledoc """
  "Move into columns" / "Move to canvas" — the button path between the block
  canvas and a columns block — and the side-by-side preview.

  A block moves WHOLE: every declared field, its stable id, and (for rich text)
  its prose. The first version of these handlers carried a hand-picked field
  list, minted a fresh id on the way back, and removed the source block even
  when the destination column was full; each test below pins one of those.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Blocks.Columns
  alias KilnCMS.Blocks.Heading
  alias KilnCMS.Blocks.Image
  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.Blocks.RichText
  alias KilnCMS.CMS
  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMSWeb.ContentEditor.BlockParams

  @password "password123456"

  defp authed_user(role) do
    email = "move-#{System.unique_integer([:positive])}@example.com"

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

  defp draft_page(attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{title: "A page", slug: "mv-#{System.unique_integer([:positive])}", state: :draft},
        attrs
      )
    )
  end

  defp open_editor(conn, page) do
    {:ok, lv, _html} =
      conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

    lv
  end

  defp saved_blocks(page),
    do: CMS.get_page!(page.id, authorize?: false).blocks |> TypedBlocks.to_typed()

  # A columns block at the top of the canvas, returning its stable id.
  defp add_columns_block_at_start(lv) do
    render_hook(lv, "add_block", %{"type" => "columns", "after" => "start"})
    [_, id] = Regex.run(~r/data-block-id="([^"]+)"[^>]*data-block-type="columns"/, render(lv))
    id
  end

  defp image_block(id, media_id) do
    %{
      id: id,
      type: :image,
      content: "/uploads/pic.jpg",
      data: %{"alt" => "A pic", "caption" => "Taken at dawn", "media_id" => media_id},
      order: 0
    }
  end

  defp media, do: Ash.Seed.seed!(MediaItem, %{filename: "pic.jpg", url: "/uploads/pic.jpg"})

  describe "Move into columns" do
    test "is offered only once there is a columns block to move into", %{conn: conn} do
      image_id = Ash.UUID.generate()
      page = draft_page(%{blocks: [image_block(image_id, media().id)]})
      lv = open_editor(conn, page)

      refute has_element?(lv, "button[phx-click='nest_into_columns']")

      add_columns_block_at_start(lv)

      assert has_element?(
               lv,
               "button[phx-click='nest_into_columns'][phx-value-bid='#{image_id}']"
             )
    end

    test "carries every field and the block's id into the column", %{conn: conn} do
      image_id = Ash.UUID.generate()
      media = media()
      page = draft_page(%{blocks: [image_block(image_id, media.id)]})
      lv = open_editor(conn, page)
      cols_id = add_columns_block_at_start(lv)

      lv
      |> element("button[phx-click='nest_into_columns'][phx-value-bid='#{image_id}']")
      |> render_click()

      lv |> form("#page-editor") |> render_submit()

      # The image is gone from the canvas and sits in column 1 — caption and
      # media link included, which the nested editor does not show and the old
      # field list dropped.
      assert [%Columns{id: ^cols_id, columns: [%{"blocks" => [child]}, %{"blocks" => []}]}] =
               saved_blocks(page)

      assert child["_type"] == "image"
      assert child["id"] == image_id
      assert child["url"] == "/uploads/pic.jpg"
      assert child["caption"] == "Taken at dawn"
      assert child["media_id"] == media.id
    end

    test "a full column refuses the move and the block stays on the canvas", %{conn: conn} do
      heading_id = Ash.UUID.generate()

      page =
        draft_page(%{blocks: [%{id: heading_id, type: :heading, content: "Stay put", order: 0}]})

      lv = open_editor(conn, page)
      cols_id = add_columns_block_at_start(lv)

      for _ <- 1..20 do
        lv
        |> element(
          "button[phx-click='col_add_child'][phx-value-id='#{cols_id}'][phx-value-col='0'][phx-value-type='divider']"
        )
        |> render_click()
      end

      # Column 1 is full, so the button aims at the next column with room.
      assert has_element?(
               lv,
               "button[phx-click='nest_into_columns'][phx-value-bid='#{heading_id}'][phx-value-col='1']"
             )

      # A stale client still aiming at the full column is refused with a reason
      # — not silently relieved of the block.
      html =
        render_hook(lv, "nest_into_columns", %{
          "bid" => heading_id,
          "cols" => cols_id,
          "col" => "0"
        })

      assert html =~ "That column is full"

      lv |> form("#page-editor") |> render_submit()

      assert Enum.any?(
               saved_blocks(page),
               &match?(%Heading{id: ^heading_id, text: "Stay put"}, &1)
             )
    end
  end

  describe "Move to canvas" do
    test "keeps the child's id and fields, and lands right after its columns block",
         %{conn: conn} do
      image_id = Ash.UUID.generate()
      after_id = Ash.UUID.generate()
      media = media()

      page =
        draft_page(%{
          blocks: [
            image_block(image_id, media.id),
            %{id: after_id, type: :heading, content: "After", order: 1}
          ]
        })

      lv = open_editor(conn, page)
      add_columns_block_at_start(lv)

      lv
      |> element("button[phx-click='nest_into_columns'][phx-value-bid='#{image_id}']")
      |> render_click()

      lv
      |> element("button[phx-click='promote_child'][phx-value-child='#{image_id}']")
      |> render_click()

      lv |> form("#page-editor") |> render_submit()

      # The same id comes back — comment threads are keyed on it — with the
      # caption and media link intact, directly after the columns block.
      assert [
               %Columns{columns: [%{"blocks" => []}, %{"blocks" => []}]},
               %Image{id: ^image_id, caption: "Taken at dawn", media_id: media_id},
               %Heading{id: ^after_id}
             ] = saved_blocks(page)

      assert media_id == media.id
    end

    test "rich text survives the round trip and a later keystroke", %{conn: conn} do
      rt_id = Ash.UUID.generate()
      page = draft_page(%{blocks: [%{id: rt_id, type: :rich_text, content: "", order: 0}]})
      lv = open_editor(conn, page)

      # Prose typed in TipTap lives in `body` (Portable Text), which the form
      # does not round-trip — it rides server-side, keyed by block id.
      render_hook(lv, "rich_text_body", %{
        "id" => rt_id,
        "doc" => %{
          "type" => "doc",
          "content" => [
            %{
              "type" => "paragraph",
              "content" => [%{"type" => "text", "text" => "Hello columns"}]
            }
          ]
        }
      })

      add_columns_block_at_start(lv)

      lv
      |> element("button[phx-click='nest_into_columns'][phx-value-bid='#{rt_id}']")
      |> render_click()

      # Nested, the prose is editable where the nested editor can reach it.
      assert has_element?(lv, "input[phx-value-field='legacy_html'][value*='Hello columns']")

      lv
      |> element("button[phx-click='promote_child'][phx-value-child='#{rt_id}']")
      |> render_click()

      # The keystroke that used to rebuild the promoted block with an empty body.
      lv |> form("#page-editor", form: %{title: "Edited"}) |> render_change()
      lv |> form("#page-editor") |> render_submit()

      assert %RichText{body: [_ | _] = body} =
               Enum.find(saved_blocks(page), &match?(%RichText{id: ^rt_id}, &1))

      assert PortableText.to_html(body) =~ "Hello columns"
    end
  end

  describe "admin-only values" do
    # Moving such a block is, to EnforceBlockFieldPolicy, clearing the value in
    # one tree and setting it in the other — refused for a non-admin at save.
    test "hold a non-admin's move back, never an admin's" do
      featured = %{"_union_type" => "quote", "text" => "Q", "featured" => true}

      assert BlockParams.holds_restricted_values?(featured, :editor)
      refute BlockParams.holds_restricted_values?(featured, :admin)
      refute BlockParams.holds_restricted_values?(%{featured | "featured" => false}, :editor)

      refute BlockParams.holds_restricted_values?(
               %{"_type" => "quote", "featured" => "false"},
               :editor
             )
    end
  end

  describe "preview" do
    test "switching to side-by-side catches up a preview gone stale off-tab", %{conn: conn} do
      heading_id = Ash.UUID.generate()

      page =
        draft_page(%{blocks: [%{id: heading_id, type: :heading, content: "Alpha", order: 0}]})

      lv = open_editor(conn, page)

      # An edit while Settings is showing only marks the preview stale.
      render_hook(lv, "switch_inspector_tab", %{"tab" => "settings"})
      render_hook(lv, "duplicate_block", %{"bid" => heading_id})

      render_hook(lv, "toggle_preview_layout", %{})

      preview = lv |> element("article.prose") |> render()
      assert length(Regex.scan(~r/>Alpha</, preview)) == 2
      assert has_element?(lv, "button[phx-click='toggle_preview_layout'][aria-pressed='true']")
    end

    test "a titled draft with no blocks still previews its title", %{conn: conn} do
      page = draft_page(%{title: "Only a title", blocks: []})
      lv = open_editor(conn, page)

      assert lv |> element("article.prose") |> render() =~ "Only a title"
    end
  end
end
