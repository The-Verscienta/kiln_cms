defmodule KilnCMSWeb.ContentEditorMarkdownTest do
  @moduledoc """
  Markdown in the content editor (`KilnCMSWeb.ContentEditor.MarkdownImport`):
  a paste into a rich-text block is answered with the TipTap document to
  insert, and a `.md` import is held for confirmation, then lands as typed
  blocks (plus the title/slug the file supplies) that a Save persists.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_editor do
    email = "md-import-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
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

  defp open(conn, blocks \\ []) do
    editor = authed_editor()

    page =
      CMS.create_page!(
        %{
          title: "Before import",
          slug: "md-import-#{System.unique_integer([:positive])}",
          blocks: blocks
        },
        actor: editor
      )

    {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/pages/#{page.id}")
    {lv, page}
  end

  defp saved(page), do: CMS.get_page!(page.id, authorize?: false)

  defp types(page),
    do: Enum.map(page.blocks, &(&1.value.__struct__ |> Kiln.Block.Info.name() |> to_string()))

  defp prose(%Ash.Union{value: %{body: body}}), do: PortableText.to_plain_text(body)

  defp import_file(lv, text, name \\ "guide.md"),
    do: render_hook(lv, "markdown_import", %{"name" => name, "text" => text})

  defp apply_import(lv, mode),
    do:
      lv
      |> element(~s(#markdown-import-dialog button[phx-value-mode="#{mode}"]))
      |> render_click()

  defp save(lv), do: lv |> form("#page-editor") |> render_submit()

  describe "paste" do
    test "Markdown-shaped text is answered with the TipTap document to insert", %{conn: conn} do
      {lv, _page} = open(conn)

      render_hook(lv, "markdown_paste", %{"text" => "## Steps\n\n- one\n- **two**"})

      assert_reply(lv, %{
        doc: %{
          "type" => "doc",
          "content" => [
            %{"type" => "heading", "attrs" => %{"level" => 2}},
            %{"type" => "bulletList", "content" => [_one, _two]}
          ]
        }
      })
    end

    test "a paste over the size limit is refused, so the client pastes it plain", %{conn: conn} do
      {lv, _page} = open(conn)

      render_hook(lv, "markdown_paste", %{
        "text" => String.duplicate("a", KilnCMS.Markdown.max_bytes() + 1)
      })

      assert_reply(lv, %{error: "too_large"})
    end
  end

  describe "import" do
    test "the file waits for confirmation, then replaces the body and sets title and slug",
         %{conn: conn} do
      {lv, page} = open(conn, [%{"_type" => "divider"}])
      slug = "imported-#{System.unique_integer([:positive])}"

      import_file(lv, """
      ---
      slug: #{slug}
      ---
      # Imported guide

      Intro paragraph.

      ![A map](https://img.example.com/map.png "The map")

      ## Details

      | A | B |
      |---|---|
      | 1 | 2 |
      """)

      # Nothing is written until the author confirms.
      assert has_element?(lv, "#markdown-import-dialog", "Import guide.md")
      assert has_element?(lv, "#markdown-import-dialog", "Imported guide")
      assert has_element?(lv, "#markdown-import-dialog", slug)
      assert types(saved(page)) == ["divider"]

      apply_import(lv, "replace")
      refute has_element?(lv, "#markdown-import-dialog")
      save(lv)

      stored = saved(page)
      assert {stored.title, stored.slug} == {"Imported guide", slug}
      assert types(stored) == ["rich_text", "image", "rich_text"]

      [intro, image, details] = stored.blocks
      assert prose(intro) == "Intro paragraph."

      assert {image.value.url, image.value.alt, image.value.caption} ==
               {"https://img.example.com/map.png", "A map", "The map"}

      assert [%{"style" => "h2"}, %{"_type" => "table"}] = details.value.body
    end

    test "append keeps the existing blocks ahead of the imported ones", %{conn: conn} do
      {lv, page} = open(conn, [%{"_type" => "divider"}])

      import_file(lv, "Added at the end.")
      apply_import(lv, "append")
      save(lv)

      stored = saved(page)
      assert types(stored) == ["divider", "rich_text"]
      assert prose(List.last(stored.blocks)) == "Added at the end."
      assert stored.title == "Before import"
    end

    test "an unticked field is left alone", %{conn: conn} do
      {lv, page} = open(conn)

      import_file(lv, "# Not this title\n\nBody.")
      lv |> element("#markdown-import-title") |> render_click()
      apply_import(lv, "replace")
      save(lv)

      stored = saved(page)
      assert stored.title == "Before import"
      assert Enum.map(stored.blocks, &prose/1) == ["Body."]
    end

    test "cancel discards the pending import", %{conn: conn} do
      {lv, page} = open(conn, [%{"_type" => "divider"}])

      import_file(lv, "Never applied.")
      render_click(lv, "markdown_import_cancel")
      refute has_element?(lv, "#markdown-import-dialog")
      assert render_click(lv, "markdown_import_apply", %{"mode" => "replace"})
      save(lv)

      assert types(saved(page)) == ["divider"]
    end

    test "a file over the size limit is refused with a message", %{conn: conn} do
      {lv, _page} = open(conn)

      html = render_hook(lv, "markdown_import", %{"name" => "big.md", "too_large" => true})

      assert html =~ "That file is too large to import (the limit is 1 MB)."
      refute has_element?(lv, "#markdown-import-dialog")
    end

    test "a file with nothing to import says so", %{conn: conn} do
      {lv, _page} = open(conn)

      assert import_file(lv, "---\nslug: only-metadata\n---\n") =~
               "That file has nothing in it to import."

      refute has_element?(lv, "#markdown-import-dialog")
    end
  end
end
