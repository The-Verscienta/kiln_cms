defmodule KilnCMSWeb.ContentEditorDuplicateBlockTest do
  @moduledoc """
  Duplicating a block on the content editor's canvas (#2778).

  A rich-text block's prose rides server-side in `rich_bodies`, keyed by block
  id, and is re-injected on every validate, save and autosave — the rendered
  form round-trips only an empty `legacy_html`. The copy got a fresh id but no
  entry, so it saved empty while its editor still showed the text.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.TypedFixtures
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Blocks.Columns
  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.Blocks.RichText
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.TypedBlocks

  @password "password123456"

  defp authed_editor do
    email = "dup-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
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

  defp open_editor(conn, page) do
    {:ok, lv, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(authed_editor())
      |> live(~p"/editor/content/page/#{page.id}")

    lv
  end

  defp draft_page(blocks) do
    Ash.Seed.seed!(Page, %{
      title: "A page",
      slug: "dup-#{System.unique_integer([:positive])}",
      state: :draft,
      blocks: typed_blocks(blocks)
    })
  end

  defp saved_blocks(page),
    do: CMS.get_page!(page.id, authorize?: false).blocks |> TypedBlocks.to_typed()

  defp tiptap(text) do
    %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}
      ]
    }
  end

  # A rich-text block whose prose was typed in this session, so it lives only
  # in `rich_bodies` and the form, never in the posted `legacy_html`.
  defp page_with_typed_prose(conn, text) do
    rt_id = Ash.UUID.generate()
    page = draft_page([%{id: rt_id, type: :rich_text, content: "", order: 0}])
    lv = open_editor(conn, page)
    render_hook(lv, "rich_text_body", %{"id" => rt_id, "doc" => tiptap(text)})
    {page, lv, rt_id}
  end

  defp duplicate(lv, bid) do
    lv |> element("button[phx-click='duplicate_block'][phx-value-bid='#{bid}']") |> render_click()
  end

  defp rich_texts(page), do: Enum.filter(saved_blocks(page), &match?(%RichText{}, &1))

  defp prose(%RichText{body: body}), do: PortableText.to_html(body)

  describe "a duplicated rich-text block" do
    test "saves with its text when nothing is typed before the save", %{conn: conn} do
      {page, lv, rt_id} = page_with_typed_prose(conn, "Copied prose")

      duplicate(lv, rt_id)
      lv |> form("#page-editor") |> render_submit()

      assert [%RichText{id: ^rt_id} = original, %RichText{id: copy_id} = copy] = rich_texts(page)
      assert copy_id != rt_id
      assert prose(original) =~ "Copied prose"
      assert prose(copy) =~ "Copied prose"
    end

    test "keeps its text through a keystroke elsewhere in the form", %{conn: conn} do
      {page, lv, rt_id} = page_with_typed_prose(conn, "Survives a keystroke")

      duplicate(lv, rt_id)
      # The keystroke posts the copy's empty `legacy_html` and nothing else.
      lv |> form("#page-editor", form: %{title: "Edited"}) |> render_change()
      lv |> form("#page-editor") |> render_submit()

      assert [_original, copy] = rich_texts(page)
      assert prose(copy) =~ "Survives a keystroke"
    end

    test "keeps its own text when the original is edited afterwards", %{conn: conn} do
      {page, lv, rt_id} = page_with_typed_prose(conn, "Before the edit")

      duplicate(lv, rt_id)
      render_hook(lv, "rich_text_body", %{"id" => rt_id, "doc" => tiptap("After the edit")})
      lv |> form("#page-editor") |> render_submit()

      assert [%RichText{id: ^rt_id} = original, copy] = rich_texts(page)
      assert prose(original) =~ "After the edit"
      refute prose(original) =~ "Before the edit"
      assert prose(copy) =~ "Before the edit"
      refute prose(copy) =~ "After the edit"
    end

    test "is persisted by the draft autosave", %{conn: conn} do
      {page, lv, rt_id} = page_with_typed_prose(conn, "Autosaved copy")

      duplicate(lv, rt_id)
      lv |> form("#page-editor", form: %{title: "Edited"}) |> render_change()
      send(lv.pid, :autosave)
      _ = render(lv)

      assert [_original, copy] = rich_texts(page)
      assert prose(copy) =~ "Autosaved copy"
    end

    test "loaded from the stored body saves with its text", %{conn: conn} do
      rt_id = Ash.UUID.generate()

      page =
        Ash.Seed.seed!(Page, %{
          title: "A page",
          slug: "dup-#{System.unique_integer([:positive])}",
          state: :draft,
          blocks: [
            %{
              "_type" => "rich_text",
              "id" => rt_id,
              "body" => PortableText.from_html("<p>Stored prose</p>")
            }
          ]
        })

      lv = open_editor(conn, page)
      duplicate(lv, rt_id)
      lv |> form("#page-editor", form: %{title: "Edited"}) |> render_change()
      lv |> form("#page-editor") |> render_submit()

      assert [_original, copy] = rich_texts(page)
      assert prose(copy) =~ "Stored prose"
    end
  end

  describe "a duplicated columns block" do
    test "carries its rich-text children's text, independent of the original's",
         %{conn: conn} do
      page = draft_page([])
      lv = open_editor(conn, page)

      render_hook(lv, "add_block", %{"type" => "columns", "after" => "start"})

      [_, cols_id] =
        Regex.run(~r/data-block-id="([^"]+)"[^>]*data-block-type="columns"/, render(lv))

      render_hook(lv, "col_add_child", %{"id" => cols_id, "col" => "0", "type" => "rich_text"})

      [%{"blocks" => [%{"id" => child_id}]}, _] =
        :sys.get_state(lv.pid).socket.assigns.block_children[cols_id]

      render_hook(lv, "col_update_child", %{
        "id" => cols_id,
        "child" => child_id,
        "field" => "html",
        "value" => "<p>Nested prose</p>"
      })

      duplicate(lv, cols_id)

      render_hook(lv, "col_update_child", %{
        "id" => cols_id,
        "child" => child_id,
        "field" => "html",
        "value" => "<p>Edited original</p>"
      })

      lv |> form("#page-editor") |> render_submit()

      assert [%Columns{id: ^cols_id} = original, %Columns{} = copy] =
               Enum.filter(saved_blocks(page), &match?(%Columns{}, &1))

      assert [%{"blocks" => [original_child]}, _] = original.columns
      assert [%{"blocks" => [copy_child]}, _] = copy.columns
      assert copy_child["id"] != child_id
      assert inspect(original_child) =~ "Edited original"
      assert inspect(copy_child) =~ "Nested prose"
      refute inspect(copy_child) =~ "Edited original"
    end
  end
end
