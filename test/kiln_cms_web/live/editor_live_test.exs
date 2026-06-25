defmodule KilnCMSWeb.EditorLiveTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Category
  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post
  alias KilnCMS.CMS.Tag

  @password "password123456"

  defp authed_user(role) do
    email = "editor-#{System.unique_integer([:positive])}@example.com"

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

  defp draft_page(attrs \\ %{}) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{title: "A page", slug: "ed-#{System.unique_integer([:positive])}", state: :draft},
        attrs
      )
    )
  end

  defp draft_post(attrs \\ %{}) do
    Ash.Seed.seed!(
      Post,
      Map.merge(
        %{title: "A post", slug: "po-#{System.unique_integer([:positive])}", state: :draft},
        attrs
      )
    )
  end

  describe "/editor (content list)" do
    test "viewers are redirected away", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> log_in(authed_user(:viewer)) |> live(~p"/editor")
    end

    test "lists pages for an editor", %{conn: conn} do
      draft_page(%{title: "Findable Page"})
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")
      assert html =~ "Findable Page"
    end

    test "filters the list by status", %{conn: conn} do
      draft_page(%{title: "AlphaDraft", state: :draft})
      draft_page(%{title: "BetaPub", state: :published})
      {:ok, lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")
      assert html =~ "AlphaDraft"
      assert html =~ "BetaPub"

      filtered = lv |> form("form[phx-change=filter]", %{status: "published"}) |> render_change()
      assert filtered =~ "BetaPub"
      refute filtered =~ "AlphaDraft"
    end

    test "searches the list by title", %{conn: conn} do
      draft_page(%{title: "UniqueSearchable"})
      draft_page(%{title: "HiddenOne"})
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      searched = lv |> form("form[phx-change=search]", %{q: "Searchable"}) |> render_change()
      assert searched =~ "UniqueSearchable"
      refute searched =~ "HiddenOne"
    end

    test "New page creates a draft and navigates to the editor", %{conn: conn} do
      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      lv |> element("button", "New page") |> render_click()

      assert {path, _flash} = assert_redirect(lv)
      assert path =~ ~r"^/editor/content/page/"
    end

    test "bulk publish transitions the selected page and post (admin only)", %{conn: conn} do
      page = draft_page(%{title: "BulkPage", state: :draft})
      post = draft_post(%{title: "BulkPost", state: :draft})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      lv |> element(~s(input[phx-value-key="page:#{page.id}"])) |> render_click()
      lv |> element(~s(input[phx-value-key="post:#{post.id}"])) |> render_click()
      lv |> element("button[phx-value-action='publish']") |> render_click()

      assert CMS.get_page!(page.id, authorize?: false).state == :published
      assert CMS.get_post!(post.id, authorize?: false).state == :published
    end

    test "the bulk Publish button is admin-only", %{conn: conn} do
      draft_page()

      {:ok, _lv, editor_html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      refute editor_html =~ ~s(phx-value-action="publish")

      {:ok, _lv, admin_html} =
        build_conn() |> log_in(authed_user(:admin)) |> live(~p"/editor")

      assert admin_html =~ ~s(phx-value-action="publish")
    end

    test "editor submits a draft for review from the list", %{conn: conn} do
      page = draft_page(%{title: "SubmitMe"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      lv
      |> element("button[phx-click='submit'][phx-value-id='#{page.id}']")
      |> render_click()

      assert CMS.get_page!(page.id, authorize?: false).state == :in_review
    end

    test "admin approves in-review content from the list", %{conn: conn} do
      page = draft_page(%{title: "ApproveMe", state: :in_review})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      lv
      |> element("button[phx-click='publish'][phx-value-id='#{page.id}']")
      |> render_click()

      published = CMS.get_page!(page.id, authorize?: false)
      assert published.state == :published
      assert published.published_version_id
    end

    test "select-all then bulk archive archives every visible item", %{conn: conn} do
      page = draft_page(%{title: "ArchPage"})
      post = draft_post(%{title: "ArchPost"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      lv |> element("input[phx-click='toggle_select_all']") |> render_click()
      lv |> element("button[phx-value-action='archive']") |> render_click()

      assert CMS.get_page!(page.id, authorize?: false).state == :archived
      assert CMS.get_post!(post.id, authorize?: false).state == :archived
    end

    test "the bulk Delete button is admin-only", %{conn: conn} do
      draft_page()

      {:ok, _lv, editor_html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      refute editor_html =~ "request_delete"

      {:ok, _lv, admin_html} =
        build_conn() |> log_in(authed_user(:admin)) |> live(~p"/editor")

      assert admin_html =~ "request_delete"
    end

    test "admin bulk delete asks for confirmation, then removes the items", %{conn: conn} do
      page = draft_page(%{title: "DeleteMe"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      lv |> element(~s(input[phx-value-key="page:#{page.id}"])) |> render_click()

      # First click only opens the guard; nothing is deleted yet.
      confirm_html = lv |> element("button[phx-click='request_delete']") |> render_click()
      assert confirm_html =~ "This can&#39;t be undone"
      assert Enum.any?(CMS.list_pages!(authorize?: false), &(&1.id == page.id))

      # Confirming performs the delete.
      lv |> element("button[phx-click='confirm_delete']") |> render_click()
      refute Enum.any?(CMS.list_pages!(authorize?: false), &(&1.id == page.id))
    end

    test "cancelling the guard dismisses it without deleting", %{conn: conn} do
      page = draft_page()

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      lv |> element(~s(input[phx-value-key="page:#{page.id}"])) |> render_click()
      lv |> element("button[phx-click='request_delete']") |> render_click()
      cancelled = lv |> element("button[phx-click='cancel_delete']") |> render_click()

      refute cancelled =~ "This can&#39;t be undone"
      assert Enum.any?(CMS.list_pages!(authorize?: false), &(&1.id == page.id))
    end

    test "lists posts and New post opens the post editor", %{conn: conn} do
      draft_post(%{title: "FindablePost"})
      {:ok, lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")
      assert html =~ "FindablePost"

      lv |> element("button", "New post") |> render_click()
      assert {path, _flash} = assert_redirect(lv)
      assert path =~ ~r"^/editor/content/post/"
    end
  end

  describe "/editor/posts/:id (post editor)" do
    test "saves an edited title and excerpt", %{conn: conn} do
      post = draft_post(%{title: "Old post"})

      {:ok, lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/posts/#{post.id}")

      assert html =~ "Edit post"
      # Excerpt is a post-only field.
      assert html =~ "Excerpt"

      lv
      |> form("#post-editor", form: %{title: "New post", excerpt: "A lead-in."})
      |> render_submit()

      saved = CMS.get_post!(post.id, authorize?: false)
      assert saved.title == "New post"
      assert saved.excerpt == "A lead-in."
    end

    test "runs the publish workflow for a post (admin only)", %{conn: conn} do
      post = draft_post()

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:admin)) |> live(~p"/editor/posts/#{post.id}")

      lv |> element("button", "Publish") |> render_click()

      assert CMS.get_post!(post.id, authorize?: false).state == :published
    end

    test "editor sees Submit for review, not Publish", %{conn: conn} do
      post = draft_post()

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/posts/#{post.id}")

      assert html =~ "Submit for review"
      refute html =~ ">Publish<"
    end
  end

  describe "draft autosave" do
    test "a draft is autosaved after editing, without submitting", %{conn: conn} do
      page = draft_page(%{title: "Old"})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # Editing marks the draft unsaved and schedules the debounced autosave.
      changed = lv |> form("#page-editor", form: %{title: "Autosaved title"}) |> render_change()
      assert changed =~ "Unsaved changes"
      assert CMS.get_page!(page.id, authorize?: false).title == "Old"

      # Fire the debounce timer.
      send(lv.pid, :autosave)
      html = render(lv)

      assert CMS.get_page!(page.id, authorize?: false).title == "Autosaved title"
      assert html =~ "Saved"
      refute html =~ "Unsaved changes"
    end

    test "published content is not autosaved", %{conn: conn} do
      page = draft_page(%{title: "Live", state: :published})

      {:ok, lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # No autosave indicator for non-drafts.
      refute html =~ "Unsaved changes"

      lv |> form("#page-editor", form: %{title: "Sneaky edit"}) |> render_change()
      send(lv.pid, :autosave)
      render(lv)

      # The published record is only changed via the explicit Save button.
      assert CMS.get_page!(page.id, authorize?: false).title == "Live"
    end
  end

  describe "/editor/trash" do
    test "editors are redirected away", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/editor"}}} =
               conn |> log_in(authed_user(:editor)) |> live(~p"/editor/trash")
    end

    test "admin sees trashed content and restores it", %{conn: conn} do
      page = draft_page(%{title: "TrashedPage"})
      admin = authed_user(:admin)
      :ok = CMS.destroy_page(page, actor: admin)

      # Soft-deleted: hidden from the normal listing, visible in trash.
      refute Enum.any?(CMS.list_pages!(authorize?: false), &(&1.id == page.id))

      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/trash")
      assert html =~ "TrashedPage"

      lv |> element("button[phx-value-id='#{page.id}']") |> render_click()

      # Gone from trash, back in the main listing.
      refute render(lv) =~ "TrashedPage"
      assert Enum.any?(CMS.list_pages!(authorize?: false), &(&1.id == page.id))
    end

    test "empty trash asks for confirmation, then permanently deletes everything", %{conn: conn} do
      page = draft_page(%{title: "PurgeMe"})
      admin = authed_user(:admin)
      :ok = CMS.destroy_page(page, actor: admin)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/trash")

      # First click only opens the guard; nothing is purged yet.
      confirm_html = lv |> element("button[phx-click='request_empty']") |> render_click()
      assert confirm_html =~ "This can&#39;t be undone"
      assert Enum.any?(CMS.list_trashed_pages!(authorize?: false), &(&1.id == page.id))

      # Confirming hard-deletes everything in the trash.
      lv |> element("button[phx-click='confirm_empty']") |> render_click()
      refute Enum.any?(CMS.list_trashed_pages!(authorize?: false), &(&1.id == page.id))
      assert render(lv) =~ "Trash is empty"
    end

    test "the trash link is shown to admins only", %{conn: conn} do
      {:ok, _lv, editor_html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")
      refute editor_html =~ "/editor/trash"

      {:ok, _lv, admin_html} = build_conn() |> log_in(authed_user(:admin)) |> live(~p"/editor")
      assert admin_html =~ "/editor/trash"
    end
  end

  describe "who's editing (presence)" do
    test "a lone editor sees no presence roster", %{conn: conn} do
      page = draft_page()

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      refute render(lv) =~ "editing"
    end

    test "the roster shows a count and names everyone editing", %{conn: _conn} do
      page = draft_page()
      user_a = authed_user(:editor)
      user_b = authed_user(:editor)
      name_b = user_b.email |> to_string() |> String.split("@") |> hd()

      {:ok, lv_a, _html} =
        build_conn() |> log_in(user_a) |> live(~p"/editor/pages/#{page.id}")

      refute render(lv_a) =~ "editing"

      {:ok, _lv_b, _html} =
        build_conn() |> log_in(user_b) |> live(~p"/editor/pages/#{page.id}")

      # lv_a receives the presence_diff and re-renders with both editors.
      html = render(lv_a)
      assert html =~ "2 editing"
      # user_b appears in their avatar's tooltip.
      assert html =~ name_b
    end
  end

  describe "image block picker" do
    test "picking a library image sets the block's url and media_id", %{conn: conn} do
      media = Ash.Seed.seed!(MediaItem, %{filename: "x.jpg", url: "/uploads/x"})
      page = draft_page(%{blocks: [%{type: :image, content: "", order: 0}]})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # Open the picker for block 0, then pick the seeded image.
      lv |> element("button[phx-click='open_picker'][phx-value-index='0']") |> render_click()

      lv
      |> element("button[phx-click='pick_image'][phx-value-id='#{media.id}']")
      |> render_click()

      lv |> form("#page-editor") |> render_submit()

      [block] = CMS.get_page!(page.id, authorize?: false).blocks
      assert block.content == "/uploads/x"
      assert block.data["media_id"] == media.id
    end
  end

  describe "media library browser (editor chrome)" do
    test "opening from chrome and picking inserts a new image block", %{conn: conn} do
      media = Ash.Seed.seed!(MediaItem, %{filename: "hero.jpg", url: "/uploads/hero"})
      # Start with no blocks at all — the browser is reachable without one.
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # Reachable from the editor chrome (not a per-block button).
      lv |> element("button[phx-click='open_media_browser']") |> render_click()

      lv
      |> element(
        "button[phx-click='pick_image'][phx-value-index='new'][phx-value-id='#{media.id}']"
      )
      |> render_click()

      lv |> form("#page-editor") |> render_submit()

      [block] = CMS.get_page!(page.id, authorize?: false).blocks
      assert to_string(block.type) == "image"
      assert block.content == "/uploads/hero"
      assert block.data["media_id"] == media.id
    end

    test "searching filters the browser grid", %{conn: conn} do
      keep = Ash.Seed.seed!(MediaItem, %{filename: "mountain.jpg", url: "/uploads/mountain"})
      drop = Ash.Seed.seed!(MediaItem, %{filename: "ocean.jpg", url: "/uploads/ocean"})
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> element("button[phx-click='open_media_browser']") |> render_click()

      html =
        lv |> form("#media-browser-filter", %{q: "mountain"}) |> render_change()

      assert html =~ "phx-value-id=\"#{keep.id}\""
      refute html =~ "phx-value-id=\"#{drop.id}\""
    end
  end

  describe "live cursors (collaborative field focus)" do
    alias KilnCMSWeb.Presence

    test "focusing and leaving a field broadcasts cursor events", %{conn: conn} do
      page = draft_page()
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, Presence.topic("page", page.id))

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> element(~s(input[name="form[title]"])) |> render_focus()
      assert_receive {:cursor, %{field: "title"}}

      lv |> element(~s(input[name="form[title]"])) |> render_blur()
      assert_receive {:cursor, %{field: nil}}
    end

    test "renders a badge for another editor's focused field, and clears it", %{conn: conn} do
      page = draft_page()

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      topic = Presence.topic("page", page.id)
      cursor = %{id: "other-editor", name: "bob", field: "title"}

      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic, {:cursor, cursor})
      assert render(lv) =~ "bob"

      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic, {:cursor, %{cursor | field: nil}})
      refute render(lv) =~ "bob"
    end

    test "soft-locks a field (readonly + ring) while another editor holds it", %{conn: conn} do
      page = draft_page()

      {:ok, lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      refute html =~ "ring-warning"

      topic = Presence.topic("page", page.id)
      cursor = %{id: "other-editor", name: "bob", field: "title"}

      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic, {:cursor, cursor})
      locked = render(lv)
      assert locked =~ "ring-warning"
      assert locked =~ "readonly"

      # Releases automatically when they leave the field.
      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic, {:cursor, %{cursor | field: nil}})
      refute render(lv) =~ "ring-warning"
    end

    test "simultaneous focus is broken by id — the lower id keeps the field", %{conn: conn} do
      page = draft_page()

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # We focus the title ourselves (sets self_field). Our id is a UUID (hex),
      # so it sorts between "0000…" and "zzzz…".
      lv |> element(~s(input[name="form[title]"])) |> render_focus()
      topic = Presence.topic("page", page.id)

      # A collaborator with a HIGHER id also on title -> we outrank them -> ours.
      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        topic,
        {:cursor, %{id: "zzzz-higher", name: "zoe", field: "title"}}
      )

      refute render(lv) =~ "ring-warning"

      # A collaborator with a LOWER id also on title -> they win -> locked for us.
      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        topic,
        {:cursor, %{id: "0000-lower", name: "abe", field: "title"}}
      )

      assert render(lv) =~ "ring-warning"
    end
  end

  describe "decoupled preview (PubSub)" do
    alias KilnCMSWeb.PreviewLive

    test "renders the current content", %{conn: conn} do
      page =
        draft_page(%{
          title: "PreviewTitle",
          blocks: [%{type: :heading, content: "PreviewHeading", order: 0}]
        })

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/preview/page/#{page.id}")

      assert html =~ "PreviewTitle"
      assert html =~ "PreviewHeading"
    end

    test "updates live when a preview event is broadcast", %{conn: conn} do
      page = draft_page()

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/preview/page/#{page.id}")

      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        PreviewLive.topic("page", page.id),
        {:preview_update,
         %{title: "LiveTitle", blocks: [%{type: "heading", content: "LiveBlock"}]}}
      )

      html = render(lv)
      assert html =~ "LiveTitle"
      assert html =~ "LiveBlock"
    end

    test "the editor broadcasts preview updates on change", %{conn: conn} do
      page = draft_page()
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, PreviewLive.topic("page", page.id))

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> form("#page-editor", form: %{title: "Broadcasted"}) |> render_change()

      assert_receive {:preview_update, %{title: "Broadcasted"}}
    end

    test "renders with public-site fidelity (public shell + prose article)", %{conn: conn} do
      page = draft_page()

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/preview/page/#{page.id}")

      # The public layout chrome and prose typography wrap the content, so the
      # preview matches the live site rather than rendering bare blocks.
      assert html =~ "prose"
      assert html =~ "Powered by KilnCMS."
      assert html =~ "Draft preview"
    end

    test "a post preview shows the excerpt", %{conn: conn} do
      post = draft_post(%{title: "PostTitle", excerpt: "A teaser line"})

      {:ok, lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/preview/post/#{post.id}")

      assert html =~ "A teaser line"

      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        PreviewLive.topic("post", post.id),
        {:preview_update, %{title: "PostTitle", excerpt: "Updated teaser", blocks: []}}
      )

      assert render(lv) =~ "Updated teaser"
    end
  end

  describe "/editor/pages/:id (block editor)" do
    test "saves an edited title", %{conn: conn} do
      page = draft_page(%{title: "Old title"})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> form("#page-editor", form: %{title: "New title"}) |> render_submit()

      assert CMS.get_page!(page.id, authorize?: false).title == "New title"
    end

    test "adds a block and persists its content", %{conn: conn} do
      page = draft_page()

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> element("button[phx-value-type='heading']") |> render_click()

      lv
      |> form("#page-editor", form: %{blocks: %{"0" => %{content: "A nice heading"}}})
      |> render_submit()

      assert [%{type: :heading, content: "A nice heading"}] =
               CMS.get_page!(page.id, authorize?: false).blocks
    end

    test "reorders blocks via the sortable hook and persists the new order", %{conn: conn} do
      page =
        draft_page(%{
          blocks: [
            %{type: :heading, content: "A", order: 0},
            %{type: :rich_text, content: "B", order: 1}
          ]
        })

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # Simulate the Sortable hook pushing the new order (B before A).
      render_hook(lv, "reorder", %{"order" => ["1", "0"]})
      lv |> form("#page-editor") |> render_submit()

      assert [%{content: "B"}, %{content: "A"}] =
               CMS.get_page!(page.id, authorize?: false).blocks
    end

    test "a rich_text block's HTML content round-trips through save", %{conn: conn} do
      # TipTap mirrors its HTML into a hidden input (server-rendered value); a
      # save round-trips it. (The live editing itself is browser-verified.)
      page =
        draft_page(%{
          blocks: [%{type: :rich_text, content: "<p>Hi <strong>there</strong></p>", order: 0}]
        })

      {:ok, lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # The rich_text block renders the TipTap mount + hidden input, not a textarea.
      assert html =~ ~s(phx-hook="RichText")

      lv |> form("#page-editor") |> render_submit()

      assert [%{type: :rich_text, content: "<p>Hi <strong>there</strong></p>"}] =
               CMS.get_page!(page.id, authorize?: false).blocks
    end

    test "the live preview reflects block content and updates on change", %{conn: conn} do
      page = draft_page(%{blocks: [%{type: :heading, content: "Original Heading", order: 0}]})
      {:ok, lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # Preview renders the heading block (distinct from the editor's textarea).
      assert html =~ ~s(text-xl font-bold">Original Heading)

      html2 =
        lv
        |> form("#page-editor", form: %{blocks: %{"0" => %{content: "Updated Heading"}}})
        |> render_change()

      assert html2 =~ ~s(text-xl font-bold">Updated Heading)
    end

    test "saves SEO & scheduling fields", %{conn: conn} do
      page = draft_page()

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv
      |> form("#page-editor",
        form: %{
          seo_title: "Meta Title",
          seo_description: "Meta description",
          canonical_url: "https://example.com/p"
        }
      )
      |> render_submit()

      saved = CMS.get_page!(page.id, authorize?: false)
      assert saved.seo_title == "Meta Title"
      assert saved.seo_description == "Meta description"
      assert saved.canonical_url == "https://example.com/p"
    end

    test "version history lists versions and restore reverts content", %{conn: conn} do
      editor = authed_user(:editor)
      # Create + update through the actions so PaperTrail records versions.
      page =
        CMS.create_page!(%{title: "Original", slug: "hist-#{System.unique_integer([:positive])}"},
          actor: editor
        )

      CMS.update_page!(page, %{title: "Changed"}, actor: editor)

      {:ok, lv, html} = conn |> log_in(editor) |> live(~p"/editor/pages/#{page.id}")
      assert html =~ "Version history"

      [create_version | _] =
        CMS.list_page_versions!(actor: editor)
        |> Enum.filter(&(&1.version_source_id == page.id))
        |> Enum.sort_by(& &1.version_inserted_at, DateTime)

      lv |> element("button[phx-value-version_id='#{create_version.id}']") |> render_click()

      assert CMS.get_page!(page.id, authorize?: false).title == "Original"
    end

    test "runs the publish workflow (admin only)", %{conn: conn} do
      page = draft_page()

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:admin)) |> live(~p"/editor/pages/#{page.id}")

      lv |> element("button", "Publish") |> render_click()

      published = CMS.get_page!(page.id, authorize?: false)
      assert published.state == :published
      assert published.published_version_id
    end

    test "editor submits a page for review from the editor", %{conn: conn} do
      page = draft_page()

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> element("button", "Submit for review") |> render_click()

      assert CMS.get_page!(page.id, authorize?: false).state == :in_review
    end
  end

  describe "relationship pickers" do
    defp uniq, do: System.unique_integer([:positive])

    test "the editor renders the organization & relationships section", %{conn: conn} do
      post = draft_post()

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/posts/#{post.id}")

      assert html =~ "Organization &amp; relationships"
      assert html =~ "Category"
      assert html =~ "Tags"
      assert html =~ "Featured image"
      assert html =~ "Related posts"
    end

    test "assigns a category, tags and a featured image on save", %{conn: conn} do
      post = draft_post()
      cat = Ash.Seed.seed!(Category, %{name: "News", slug: "c-#{uniq()}"})
      tag = Ash.Seed.seed!(Tag, %{name: "elixir", slug: "t-#{uniq()}"})
      img = Ash.Seed.seed!(MediaItem, %{filename: "hero.jpg"})

      {:ok, lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/posts/#{post.id}")

      # The seeded taxonomy/media appear as options.
      assert html =~ "News"
      assert html =~ "elixir"
      assert html =~ "hero.jpg"

      lv
      |> form("#post-editor",
        form: %{category_id: cat.id, featured_image_id: img.id, tag_ids: [tag.id]}
      )
      |> render_submit()

      saved = CMS.get_post!(post.id, authorize?: false, load: [:tags])
      assert saved.category_id == cat.id
      assert saved.featured_image_id == img.id
      assert [%{id: tag_id}] = saved.tags
      assert tag_id == tag.id
    end

    test "an existing tag link is pre-selected in the picker", %{conn: conn} do
      tag = Ash.Seed.seed!(Tag, %{name: "preselected", slug: "t-#{uniq()}"})
      editor = authed_user(:editor)

      post =
        CMS.create_post!(%{title: "T", slug: "p-#{uniq()}", tag_ids: [tag.id]}, actor: editor)

      {:ok, _lv, html} = conn |> log_in(editor) |> live(~p"/editor/posts/#{post.id}")

      # The tag's <option> is rendered with the `selected` attribute even before
      # the user touches the field (so an untouched save won't wipe the link).
      assert html =~ ~r/<option selected[^>]*value="#{tag.id}"/
    end

    test "links a related post on save", %{conn: conn} do
      post = draft_post(%{title: "Main"})
      other = draft_post(%{title: "SiblingPost"})

      {:ok, lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/posts/#{post.id}")

      assert html =~ "SiblingPost"

      lv
      |> form("#post-editor", form: %{related_post_ids: [other.id]})
      |> render_submit()

      saved = CMS.get_post!(post.id, authorize?: false, load: [:related_posts])
      assert [%{id: rel_id}] = saved.related_posts
      assert rel_id == other.id
    end
  end

  describe "generic content route (content-type registry)" do
    test "the content list offers a New button per discovered content type", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")
      assert html =~ "New page"
      assert html =~ "New post"
    end

    test "edits a page via the generic /editor/content/:type/:id route", %{conn: conn} do
      page = draft_page(%{title: "Generic old"})

      {:ok, lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/content/page/#{page.id}")

      assert html =~ "Edit page"

      lv |> form("#page-editor", form: %{title: "Generic new"}) |> render_submit()
      assert CMS.get_page!(page.id, authorize?: false).title == "Generic new"
    end

    test "edits a post (excerpt field shown) via the generic route", %{conn: conn} do
      post = draft_post()

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/content/post/#{post.id}")

      assert html =~ "Edit post"
      assert html =~ "Excerpt"
    end

    test "an unknown content type redirects to the content list", %{conn: conn} do
      id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/editor"}}} =
               conn |> log_in(authed_user(:editor)) |> live(~p"/editor/content/widget/#{id}")
    end
  end
end
