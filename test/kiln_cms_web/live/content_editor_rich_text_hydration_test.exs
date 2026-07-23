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
