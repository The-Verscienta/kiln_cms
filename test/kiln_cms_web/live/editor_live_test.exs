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

  # Blocks are stored as the typed union (Kiln v2); read them back as legacy maps
  # (`%{type:, content:, data:}`) for assertions.
  defp blocks_legacy(record) do
    record.blocks
    |> KilnCMS.CMS.TypedBlocks.to_typed()
    |> KilnCMS.CMS.TypedBlocks.to_legacy()
  end

  defp page_versions(page_id) do
    CMS.list_page_versions!(authorize?: false)
    |> Enum.filter(&(&1.version_source_id == page_id))
  end

  defp autosave_versions(page_id),
    do: Enum.filter(page_versions(page_id), &(&1.version_action_name == :autosave))

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

    # #161: the filter and search fields are labeled for assistive tech.
    test "labels the filter and search fields", %{conn: conn} do
      draft_page(%{title: "Some content"})
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")
      assert html =~ ~s(aria-label="Filter by status")
      assert html =~ ~s(aria-label="Search by title")
      assert html =~ ~s(for="content-status-filter")
    end

    # #156: the editor links to the media library for discoverability.
    test "links to the media library", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")
      assert html =~ ~s(href="/media")
      assert html =~ "Media"
    end

    # #155: workflow state labels are humanized and localized, not raw atoms.
    test "humanizes workflow state labels", %{conn: conn} do
      draft_page(%{title: "ReviewMe", state: :in_review})
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      # The badge and the status filter both show "In review", not "in_review".
      assert html =~ "In review"
      # The status filter shows humanized option labels.
      assert html =~ ~r/<option[^>]*>\s*Draft\s*</
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

      # Editing shows a "Saving…" state and schedules the debounced autosave (#136).
      changed = lv |> form("#page-editor", form: %{title: "Autosaved title"}) |> render_change()
      assert changed =~ "Saving"
      assert CMS.get_page!(page.id, authorize?: false).title == "Old"

      # Fire the debounce timer.
      send(lv.pid, :autosave)
      html = render(lv)

      assert CMS.get_page!(page.id, authorize?: false).title == "Autosaved title"
      # The indicator shows the saved state (the Save button's phx-disable-with
      # carries "Saving…" as an attribute regardless, so don't refute it broadly).
      assert html =~ "Saved"
      refute html =~ ~r/>\s*Saving…/
    end

    # #136: a failing autosave (invalid form) surfaces an error state, not silence.
    test "an autosave that fails validation shows an error state", %{conn: conn} do
      page = draft_page(%{title: "Has title"})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # Title is required — clearing it makes the autosave submit fail validation.
      lv |> form("#page-editor", form: %{title: ""}) |> render_change()
      send(lv.pid, :autosave)
      html = render(lv)

      assert html =~ "Couldn&#39;t autosave"
      # The invalid edit was not persisted.
      assert CMS.get_page!(page.id, authorize?: false).title == "Has title"
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

    test "repeated autosaves coalesce into a single version (issue #32)", %{conn: conn} do
      page = draft_page(%{title: "Draft"})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # Several edit-then-autosave cycles, the way the debounce timer fires
      # between editor pauses.
      for title <- ~w(One Two Three Four) do
        lv |> form("#page-editor", form: %{title: title}) |> render_change()
        send(lv.pid, :autosave)
        render(lv)
      end

      # The live record always holds the latest edit...
      assert CMS.get_page!(page.id, authorize?: false).title == "Four"
      # ...but the four autosaves left exactly one version, not four.
      assert length(autosave_versions(page.id)) == 1
    end

    test "a manual save is versioned distinctly from coalesced autosaves", %{conn: conn} do
      page = draft_page(%{title: "Draft"})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # A run of autosaves collapses to one version.
      lv |> form("#page-editor", form: %{title: "Autosaved"}) |> render_change()
      send(lv.pid, :autosave)
      render(lv)
      assert length(autosave_versions(page.id)) == 1

      # An explicit Save writes its own, separately-named version...
      lv |> form("#page-editor", form: %{title: "Saved"}) |> render_submit()
      assert Enum.any?(page_versions(page.id), &(&1.version_action_name == :update))

      # ...and a fresh autosave run after it starts a new coalesced version
      # rather than swallowing the manual one.
      lv |> form("#page-editor", form: %{title: "Autosaved again"}) |> render_change()
      send(lv.pid, :autosave)
      render(lv)

      assert length(autosave_versions(page.id)) == 2
      assert Enum.any?(page_versions(page.id), &(&1.version_action_name == :update))
    end
  end

  describe "/editor/trash" do
    test "editors are redirected away", %{conn: conn} do
      assert {:error,
              {:redirect,
               %{to: "/", flash: %{"error" => "You need admin access to view that page."}}}} =
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

    test "the roster shows a count and display names, not emails (#214)", %{conn: _conn} do
      page = draft_page()
      user_a = authed_user(:editor)
      user_b = authed_user(:editor)

      # Give user_b a display name; the roster must show it, not their email.
      Ash.update!(Ash.Changeset.for_update(user_b, :update_profile, %{name: "Bob Editor"}),
        authorize?: false
      )

      local_b = user_b.email |> to_string() |> String.split("@") |> hd()

      {:ok, lv_a, _html} =
        build_conn() |> log_in(user_a) |> live(~p"/editor/pages/#{page.id}")

      refute render(lv_a) =~ "editing"

      {:ok, _lv_b, _html} =
        build_conn() |> log_in(user_b) |> live(~p"/editor/pages/#{page.id}")

      # lv_a receives the presence_diff and re-renders with both editors.
      html = render(lv_a)
      assert html =~ "2 editing"
      # user_b appears in their avatar's tooltip by display name…
      assert html =~ "Bob Editor"
      # …and never by their email local-part.
      refute html =~ local_b
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

      [block] = blocks_legacy(CMS.get_page!(page.id, authorize?: false))
      assert block.content == "/uploads/x"
      assert block.data["media_id"] == media.id
    end

    # Regression for #169: the picker is a labeled modal dialog with a focus trap.
    test "the picker exposes dialog semantics and a focus trap", %{conn: conn} do
      page = draft_page(%{blocks: [%{type: :image, content: "", order: 0}]})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      picker =
        lv |> element("button[phx-click='open_picker'][phx-value-index='0']") |> render_click()

      assert picker =~ ~s(role="dialog")
      assert picker =~ ~s(aria-modal="true")
      assert picker =~ ~s(aria-labelledby="image-picker-title")
      assert picker =~ ~s(id="image-picker-title")
      assert picker =~ ~s(phx-hook="FocusTrap")
    end
  end

  describe "block inserter (slash menu)" do
    test "menu lists an option for every registered block type", %{conn: conn} do
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      html = render(lv)

      for type <- Map.keys(KilnCMS.Blocks.registry()) do
        assert has_element?(
                 lv,
                 "button[data-inserter-item][phx-value-type='#{type}']"
               ),
               "expected an inserter option for #{type}"
      end

      # Rendered as an accessible listbox the JS hook drives.
      assert html =~ ~s(role="listbox")
      assert html =~ ~s(phx-hook="BlockInserter")
    end

    test "selecting an option inserts a block sub-form into the editor", %{conn: conn} do
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      refute has_element?(lv, "button[phx-click='remove_block']")

      lv
      |> element("button[data-inserter-item][phx-value-type='heading']")
      |> render_click()

      assert has_element?(lv, "button[phx-click='remove_block']")
    end

    test "an inserted block persists on save", %{conn: conn} do
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # `divider` has no required fields, so it round-trips through save unedited.
      lv
      |> element("button[data-inserter-item][phx-value-type='divider']")
      |> render_click()

      lv |> form("#page-editor") |> render_submit()

      assert [block] = blocks_legacy(CMS.get_page!(page.id, authorize?: false))
      assert to_string(block.type) == "divider"
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

      [block] = blocks_legacy(CMS.get_page!(page.id, authorize?: false))
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

      # Scope to the cursor badge's title — a bare "bob" also matches unrelated
      # markup (e.g. the inserter's `role="combobox"`).
      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic, {:cursor, cursor})
      assert render(lv) =~ "bob is editing"

      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic, {:cursor, %{cursor | field: nil}})
      refute render(lv) =~ "bob is editing"
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

    # #140: rich-text blocks participate in the same collaborative locking as the
    # title/slug/DSL inputs (the TipTap editor broadcasts focus/blur via its hook).
    test "soft-locks a rich-text block while another editor holds it", %{conn: conn} do
      page = draft_page(%{blocks: [%{type: :rich_text, content: "<p>hi</p>", order: 0}]})

      {:ok, lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      refute html =~ "ring-warning"

      # The block's lock field name (the legacy_html form field) is on the wrapper.
      [_, field] = Regex.run(~r/data-lock-field="([^"]+)"/, html)

      topic = Presence.topic("page", page.id)
      cursor = %{id: "other-editor", name: "bob", field: field}

      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic, {:cursor, cursor})
      locked = render(lv)
      assert locked =~ "ring-warning"
      assert locked =~ "bob is editing"

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

    # Regression for #134: the broadcast payload for a rich-text block must carry
    # the rendered HTML (legacy_html), not the empty Portable Text `body` that a
    # primary-field lookup would pick — otherwise the pop-out preview is blank.
    test "broadcast payload carries rich-text HTML, not empty body", %{conn: conn} do
      page =
        draft_page(%{
          title: "RTPage",
          blocks: [%{type: :rich_text, content: "<p>Pop-out RichText</p>", order: 0}]
        })

      Phoenix.PubSub.subscribe(KilnCMS.PubSub, PreviewLive.topic("page", page.id))

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> form("#page-editor", form: %{title: "RTPage edited"}) |> render_change()

      assert_receive {:preview_update, %{blocks: blocks}}
      assert Enum.any?(blocks, &(&1.type == "rich_text" and &1.content =~ "Pop-out RichText"))
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

      # Native union member field for a heading is `text` (not legacy `content`).
      lv
      |> form("#page-editor", form: %{blocks: %{"0" => %{text: "A nice heading"}}})
      |> render_submit()

      assert [%{type: :heading, content: "A nice heading"}] =
               blocks_legacy(CMS.get_page!(page.id, authorize?: false))
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
               blocks_legacy(CMS.get_page!(page.id, authorize?: false))
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
               blocks_legacy(CMS.get_page!(page.id, authorize?: false))
    end

    test "the live preview reflects block content and updates on change", %{conn: conn} do
      page = draft_page(%{blocks: [%{type: :heading, content: "Original Heading", order: 0}]})
      {:ok, lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # Preview renders the heading block through the typed serializers — i.e.
      # exactly what firing/delivery produces (Kiln v2 preview parity).
      assert html =~ "<h2>Original Heading</h2>"

      html2 =
        lv
        |> form("#page-editor", form: %{blocks: %{"0" => %{text: "Updated Heading"}}})
        |> render_change()

      assert html2 =~ "<h2>Updated Heading</h2>"
    end

    test "the block palette is driven by the typed block registry", %{conn: conn} do
      page = draft_page()

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # Every registered typed block type is offered (incl. ones never in the old
      # hardcoded palette, e.g. `custom`).
      for type <- ~w(rich_text heading quote image embed divider custom) do
        assert html =~ ~s(phx-value-type="#{type}")
      end
    end

    test "renders DSL-declared fields per block, gated by field-level policy", %{conn: conn} do
      page =
        draft_page(%{
          blocks: [%{type: :quote, content: "Q", data: %{"citation" => "me"}, order: 0}]
        })

      # An editor sees the quote's text + citation, but NOT the admin-only featured flag.
      {:ok, _lv, editor_html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # Native union member fields: form[blocks][0][citation], etc.
      assert editor_html =~ "[citation]"
      refute editor_html =~ "[featured]"

      # An admin additionally sees the featured field.
      {:ok, _lv, admin_html} =
        build_conn() |> log_in(authed_user(:admin)) |> live(~p"/editor/pages/#{page.id}")

      assert admin_html =~ "[citation]"
      assert admin_html =~ "[featured]"
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

  # Regression for #133: every authoring LiveView must pass current_user to
  # Layouts.app so the header shows Sign out / Editor / Settings instead of
  # Sign in while the editor is actively working.
  describe "header navigation (current_user in layout)" do
    test "content list shows authenticated nav for a signed-in editor", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      assert html =~ "Sign out"
      refute html =~ ~r/>\s*Sign in\s*</
      assert html =~ "Editor"
      assert html =~ "Settings"
      # #166: the icon-only theme toggle buttons are labeled.
      assert html =~ ~s(aria-label="Use dark theme")
      assert html =~ ~s(aria-label="Use light theme")
    end

    # #139: ⌘K targets a LiveView `navigate` link (data-phx-link="redirect"), so
    # the jump to search is a client-side navigation, not a full page reload.
    test "renders a client-side navigate target for the search shortcut", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      assert html =~ ~s(id="cmdk-search-link")
      assert html =~ ~s(data-phx-link="redirect")
      assert html =~ ~s(href="/editor/search")
    end

    test "content editor shows authenticated nav for a signed-in editor", %{conn: conn} do
      page = draft_page(%{title: "NavPage"})

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/content/page/#{page.id}")

      assert html =~ "Sign out"
      refute html =~ ~r/>\s*Sign in\s*</
    end
  end

  # Regression for #170: rich-text blocks must be labeled in the accessibility
  # tree — a named editor surface and a labeled formatting toolbar. (The TipTap
  # contenteditable's own aria-label is applied client-side from data-editor-label.)
  describe "rich-text block accessibility (#170)" do
    test "rich-text block renders group + toolbar semantics and an editor label", %{conn: conn} do
      page =
        draft_page(%{
          title: "A11yPage",
          blocks: [%{type: :rich_text, content: "<p>hi</p>", order: 0}]
        })

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/content/page/#{page.id}")

      assert html =~ ~s(role="group")
      assert html =~ ~s(aria-label="Rich text block")
      assert html =~ ~s(role="toolbar")
      assert html =~ ~s(aria-label="Text formatting")
      assert html =~ ~s(data-editor-label="Rich text editor")
    end

    # Regression for #135: a server-driven form replacement (conflict reload)
    # remounts rich-text blocks (new element id) so TipTap reloads from the latest
    # content instead of keeping its phx-update="ignore" editor.
    test "rich-text editors remount after a conflict reload", %{conn: conn} do
      editor = authed_user(:editor)
      page = draft_page(%{blocks: [%{type: :rich_text, content: "<p>hi</p>", order: 0}]})

      {:ok, lv, html} = conn |> log_in(editor) |> live(~p"/editor/pages/#{page.id}")
      assert html =~ "rt-0-v0"

      # Someone else saves first → this editor's save is stale → conflict.
      {:ok, _} = CMS.update_page(page, %{title: "Changed elsewhere"}, actor: editor)
      lv |> form("#page-editor") |> render_submit()

      # Reloading bumps the editor version so the rich-text block remounts.
      reloaded = lv |> element("#edit-conflict button", "Reload latest") |> render_click()
      assert reloaded =~ "rt-0-v1"
      refute reloaded =~ ~s(id="rt-0-v0")
    end

    # Regression for #171: blocks are reorderable without a pointer device.
    test "blocks can be reordered with keyboard move buttons", %{conn: conn} do
      page =
        draft_page(%{
          blocks: [
            %{type: :heading, content: "First", order: 0},
            %{type: :heading, content: "Second", order: 1}
          ]
        })

      {:ok, lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # Move-up on the first block is disabled; move-down is available.
      assert html =~
               ~r/phx-value-index="0"[^>]*phx-value-dir="up"[^>]*disabled|disabled[^>]*phx-value-index="0"[^>]*phx-value-dir="up"/

      moved =
        lv
        |> element(~s(button[phx-click="move_block"][phx-value-index="0"][phx-value-dir="down"]))
        |> render_click()

      # The new position is announced to screen readers.
      assert moved =~ "Moved block to position 2 of 2"

      # Saving persists the swapped order.
      lv |> form("#page-editor") |> render_submit()
      blocks = blocks_legacy(CMS.get_page!(page.id, authorize?: false))
      assert Enum.map(blocks, & &1.content) == ["Second", "First"]
    end

    # Regression for #174: the editor page must have exactly one h1 (the
    # "Edit <kind>" header); the preview-pane title is an h2.
    test "renders a single h1", %{conn: conn} do
      page = draft_page(%{title: "H1Page"})

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/content/page/#{page.id}")

      h1_count = (html |> String.split("<h1") |> length()) - 1
      assert h1_count == 1, "expected exactly one <h1>, found #{h1_count}"
    end

    # #151: Save and workflow buttons show a loading state while the event runs.
    test "the Save and workflow buttons have loading states", %{conn: conn} do
      page = draft_page(%{title: "LoadingPage"})

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/content/page/#{page.id}")

      assert html =~ ~s(phx-disable-with="Saving…")
      assert html =~ ~s(phx-disable-with="Submitting…")
    end

    # Regression for #138: on mobile the preview is a collapsible disclosure so it
    # doesn't bury the form; on desktop it stays inline as the sticky column.
    test "the preview is collapsible on mobile and inline on desktop", %{conn: conn} do
      page =
        draft_page(%{
          title: "PrevPage",
          blocks: [%{type: :heading, content: "PrevBlock", order: 0}]
        })

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/content/page/#{page.id}")

      assert html =~ ~r/<details[^>]*lg:hidden/
      assert html =~ "<summary"
      assert html =~ "hidden lg:block"
      assert html =~ "PrevBlock"
      # #152: removing a block asks for confirmation first.
      assert html =~
               ~r/phx-click="remove_block"[^>]*data-confirm|data-confirm[^>]*phx-click="remove_block"/
    end
  end
end
