defmodule KilnCMSWeb.ContentEditorRichTextHydrationTest do
  @moduledoc """
  The TipTap editor hydrates from `data-content`. A rich_text block whose
  prose lives in canonical Portable Text (`body` — what imports, visual
  editing, and the MCP tools write) must hydrate from the rendered body, not
  from the empty `legacy_html` — the regression opened such blocks as an empty
  editor, and a save then wiped the content (the form only round-trips
  `legacy_html`).
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin do
    email = "rt-hydrate-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
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

  test "a Portable Text body hydrates the rich text editor", %{conn: conn} do
    admin = authed_admin()

    page =
      CMS.create_page!(
        %{
          title: "PT hydration",
          slug: "pt-hydrate-#{System.unique_integer([:positive])}",
          blocks: [
            %{
              "_type" => "rich_text",
              "body" => [
                %{
                  "_type" => "block",
                  "_key" => "b0",
                  "style" => "normal",
                  "markDefs" => [],
                  "children" => [
                    %{"_type" => "span", "text" => "Imported prose survives", "marks" => []}
                  ]
                }
              ]
            }
          ]
        },
        actor: admin
      )

    {:ok, _lv, html} =
      conn
      |> log_in(admin)
      |> live(~p"/editor/content/page/#{page.id}")

    # The editor container's data-content carries the rendered body HTML
    # (attribute-escaped) — asserting on the attribute, not the preview pane.
    assert html =~ ~s(data-content="&lt;p&gt;Imported prose survives&lt;/p&gt;")
  end

  test "a form-shaped save (TipTap JSON string body) stores Portable Text", %{conn: conn} do
    admin = authed_admin()

    import KilnCMS.TipTapFixtures

    tiptap =
      Jason.encode!(doc([para("Saved from TipTap"), bullet_list([list_item(para("item"))])]))

    page =
      CMS.create_page!(
        %{
          title: "TipTap save",
          slug: "tiptap-save-#{System.unique_integer([:positive])}",
          blocks: [%{"_type" => "rich_text", "body" => tiptap}]
        },
        actor: admin
      )

    assert [%Ash.Union{value: block}] = page.blocks
    assert [%{"_type" => "block"} = para, %{"listItem" => "bullet", "level" => 1}] = block.body
    assert hd(para["children"])["text"] == "Saved from TipTap"
    assert block.legacy_html in [nil, ""]

    {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

    # And it hydrates back into the editor as rendered HTML.
    assert html =~ "Saved from TipTap"
    _ = html
  end

  test "updating an EXISTING block with a TipTap JSON string stores Portable Text", %{conn: conn} do
    _ = conn
    admin = authed_admin()

    page =
      CMS.create_page!(
        %{
          title: "Update path",
          slug: "update-path-#{System.unique_integer([:positive])}",
          blocks: [%{"_type" => "rich_text", "legacy_html" => "<p>old prose</p>"}]
        },
        actor: admin
      )

    [%Ash.Union{value: existing}] = page.blocks

    import KilnCMS.TipTapFixtures

    tiptap = Jason.encode!(doc(para("edited prose")))

    # The block editor's form posts the existing id + the hook's body JSON.
    updated =
      CMS.update_page!(
        page,
        %{
          blocks: [
            %{"_type" => "rich_text", "id" => existing.id, "body" => tiptap, "legacy_html" => ""}
          ]
        },
        actor: admin
      )

    assert [%Ash.Union{value: block}] = updated.blocks
    assert [%{"children" => [%{"text" => "edited prose"}]}] = block.body
    assert block.legacy_html in [nil, ""]
  end

  test "a rich_text_body push flows into the form and persists on save", %{conn: conn} do
    admin = authed_admin()

    page =
      CMS.create_page!(
        %{
          title: "Push flow",
          slug: "push-flow-#{System.unique_integer([:positive])}",
          blocks: [%{"_type" => "rich_text", "legacy_html" => "<p>before</p>"}]
        },
        actor: admin
      )

    [%Ash.Union{value: existing}] = page.blocks

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{page.id}")

    import KilnCMS.TipTapFixtures

    doc = doc([para("typed live"), bullet_list([list_item(para("a list item"))])])

    render_hook(lv, "rich_text_body", %{"id" => existing.id, "idx" => "0", "doc" => doc})
    lv |> form("#page-editor") |> render_submit()

    assert [%Ash.Union{value: block}] = CMS.get_page!(page.id, authorize?: false).blocks
    assert [%{"children" => [%{"text" => "typed live"}]}, %{"listItem" => "bullet"}] = block.body
    assert block.legacy_html in [nil, ""]
  end

  test "legacy_html still hydrates when there is no body", %{conn: conn} do
    admin = authed_admin()

    page =
      CMS.create_page!(
        %{
          title: "Legacy hydration",
          slug: "legacy-hydrate-#{System.unique_integer([:positive])}",
          blocks: [%{"_type" => "rich_text", "legacy_html" => "<p>Legacy prose intact</p>"}]
        },
        actor: admin
      )

    {:ok, _lv, html} =
      conn
      |> log_in(admin)
      |> live(~p"/editor/content/page/#{page.id}")

    assert html =~ ~s(data-content="&lt;p&gt;Legacy prose intact&lt;/p&gt;")
  end
end
