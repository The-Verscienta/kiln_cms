defmodule KilnCMSWeb.ContentEditorStaleBlocksTest do
  @moduledoc """
  A `phx-change`/`phx-submit`'s `blocks` params are a snapshot of the DOM the
  client had rendered when the event fired — never an instruction to add or
  remove blocks, which have their own server events (#1334).

  The race this pins down: `add_block` runs on the server, and before the
  patch that renders the new block reaches the browser, a keystroke fires
  `validate` (or a click fires `save`) with params read from the old DOM —
  no entry for the new block. `AshPhoenix.Form.validate/2` treats a touched
  `blocks` key's params as authoritative, so the missing entry read as a
  removal and the block the user just chose silently vanished; a Save inside
  the same window persisted the loss. The browser E2E probe that found it is
  quoted in the issue; these tests drive the same stale payloads directly.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_editor do
    email = "staleblk-#{System.unique_integer([:positive])}@example.com"

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

  defp draft(actor, attrs) do
    CMS.create_page!(
      Map.merge(
        %{
          title: "Stale blocks spec",
          slug: "staleblk-#{System.unique_integer([:positive])}"
        },
        attrs
      ),
      actor: actor
    )
  end

  defp block_id(page, index),
    do: page.blocks |> Enum.at(index) |> Map.fetch!(:value) |> Map.fetch!(:id)

  defp saved_block_types(page_id) do
    CMS.get_page!(page_id, authorize?: false).blocks
    |> Enum.map(&to_string(&1.value.__struct__ |> Kiln.Block.Info.name()))
  end

  describe "a validate that raced add_block" do
    test "with NO blocks params keeps the just-added block", %{conn: conn} do
      editor = authed_editor()
      page = draft(editor, %{blocks: []})

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/pages/#{page.id}")

      render_click(lv, "add_block", %{"type" => "divider"})
      assert render(lv) =~ ~s(data-sort-id="0")

      # The stale snapshot: the client's DOM predates the add_block patch, so
      # the form params carry the title keystroke and no "blocks" key at all.
      render_change(lv, "validate", %{
        "_target" => ["form", "title"],
        "form" => %{"title" => "Typed during the race"}
      })

      assert render(lv) =~ ~s(data-sort-id="0")
      refute render(lv) =~ "No blocks yet"

      # And the save (with the newest DOM, as the browser would send) persists it.
      lv |> form("#page-editor") |> render_submit()
      assert saved_block_types(page.id) == ["divider"]
    end

    test "with PARTIAL blocks params keeps the new block and the client's edits", %{conn: conn} do
      editor = authed_editor()
      page = draft(editor, %{blocks: [%{type: :heading, content: "Old heading", order: 0}]})
      heading_id = block_id(page, 0)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/pages/#{page.id}")

      # Prime the form the way a real session is primed: the first validate
      # carries the full rendered block list.
      lv |> form("#page-editor") |> render_change()

      render_click(lv, "add_block", %{"type" => "divider"})

      # Stale snapshot: only the heading was in the DOM when the keystroke
      # fired — with the hidden inputs the block card renders — carrying the
      # user's newest edit for it.
      render_change(lv, "validate", %{
        "_target" => ["form", "blocks", "0", "text"],
        "form" => %{
          "title" => page.title,
          "blocks" => %{
            "0" => %{
              "_persistent_id" => "0",
              "_union_type" => "heading",
              "id" => heading_id,
              "text" => "Edited heading"
            }
          }
        }
      })

      html = render(lv)
      assert html =~ "Edited heading"
      assert html =~ ~s(data-sort-id="1")

      lv |> form("#page-editor") |> render_submit()
      assert saved_block_types(page.id) == ["heading", "divider"]

      saved = CMS.get_page!(page.id, authorize?: false)
      assert Enum.at(saved.blocks, 0).value.text == "Edited heading"
    end

    test "a save inside the race window persists the just-added block", %{conn: conn} do
      editor = authed_editor()
      page = draft(editor, %{blocks: []})

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/pages/#{page.id}")

      render_click(lv, "add_block", %{"type" => "divider"})

      # Save clicked before the add_block patch landed: the submit's params
      # come from the old DOM — no blocks.
      render_submit(lv, "save", %{"form" => %{"title" => "Saved mid-race"}})

      assert saved_block_types(page.id) == ["divider"]
      assert CMS.get_page!(page.id, authorize?: false).title == "Saved mid-race"
    end
  end

  describe "the opposite race (stale params still carry a removed block)" do
    test "a validate does not resurrect a block the server removed", %{conn: conn} do
      editor = authed_editor()

      page =
        draft(editor, %{
          blocks: [
            %{type: :heading, content: "Keep", order: 0},
            %{type: :heading, content: "Drop", order: 1}
          ]
        })

      keep_id = block_id(page, 0)
      drop_id = block_id(page, 1)

      {:ok, lv, _html} = conn |> log_in(editor) |> live(~p"/editor/pages/#{page.id}")
      lv |> form("#page-editor") |> render_change()

      render_click(lv, "remove_block", %{"bid" => drop_id})
      refute render(lv) =~ "Drop"

      # A keystroke from the pre-removal DOM still lists both blocks.
      render_change(lv, "validate", %{
        "_target" => ["form", "blocks", "0", "text"],
        "form" => %{
          "title" => page.title,
          "blocks" => %{
            "0" => %{
              "_persistent_id" => "0",
              "_union_type" => "heading",
              "id" => keep_id,
              "text" => "Keep edited"
            },
            "1" => %{
              "_persistent_id" => "1",
              "_union_type" => "heading",
              "id" => drop_id,
              "text" => "Drop"
            }
          }
        }
      })

      html = render(lv)
      assert html =~ "Keep edited"
      refute html =~ "Drop"

      lv |> form("#page-editor") |> render_submit()
      assert saved_block_types(page.id) == ["heading"]
    end
  end
end
