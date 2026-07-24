defmodule KilnCMSWeb.EditorLiveTest do
  @moduledoc false
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

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

    # #177: bulk-select row checkboxes are named with the item title.
    test "row checkboxes have accessible names", %{conn: conn} do
      draft_page(%{title: "CheckboxRow"})
      {:ok, _lv, html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")
      assert html =~ ~s(aria-label="Select CheckboxRow")
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

    test "bulk publish confirms, then transitions the selected page and post (admin only)",
         %{conn: conn} do
      page = draft_page(%{title: "BulkPage", state: :draft})
      post = draft_post(%{title: "BulkPost", state: :draft})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      lv |> element(~s(input[phx-value-key="page:#{page.id}"])) |> render_click()
      lv |> element(~s(input[phx-value-key="post:#{post.id}"])) |> render_click()

      # First click opens the confirmation strip; nothing is published yet.
      confirm = lv |> element("button[phx-value-action='publish']") |> render_click()
      assert confirm =~ "go live on the site immediately"
      assert CMS.get_page!(page.id, authorize?: false).state == :draft

      lv |> element("button[phx-click='confirm_bulk']") |> render_click()

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

    # Audit U-H3: bulk archive used to fire on the first click with no way back.
    test "select-all then bulk archive confirms, archives, and is reversible", %{conn: conn} do
      page = draft_page(%{title: "ArchPage"})
      post = draft_post(%{title: "ArchPost"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      lv |> element("input[phx-click='toggle_select_all']") |> render_click()

      # Archive asks first.
      confirm = lv |> element("button[phx-value-action='archive']") |> render_click()
      assert confirm =~ "you can unarchive it later"
      assert CMS.get_page!(page.id, authorize?: false).state == :draft

      lv |> element("button[phx-click='confirm_bulk']") |> render_click()
      assert CMS.get_page!(page.id, authorize?: false).state == :archived
      assert CMS.get_post!(post.id, authorize?: false).state == :archived

      # And archive is no longer a one-way door: the row action reverses it.
      lv
      |> element("button[phx-click='unarchive'][phx-value-id='#{page.id}']")
      |> render_click()

      assert CMS.get_page!(page.id, authorize?: false).state == :draft
    end

    test "bulk unarchive returns archived items to draft", %{conn: conn} do
      page = draft_page(%{title: "UnarchPage", state: :archived})

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      lv |> element(~s(input[phx-value-key="page:#{page.id}"])) |> render_click()
      lv |> element("button[phx-value-action='unarchive']") |> render_click()
      lv |> element("button[phx-click='confirm_bulk']") |> render_click()

      assert CMS.get_page!(page.id, authorize?: false).state == :draft
    end

    test "the bulk Delete button is admin-only", %{conn: conn} do
      draft_page()

      {:ok, _lv, editor_html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      refute editor_html =~ ~s(phx-value-action="delete")

      {:ok, _lv, admin_html} =
        build_conn() |> log_in(authed_user(:admin)) |> live(~p"/editor")

      assert admin_html =~ ~s(phx-value-action="delete")
    end

    test "admin bulk delete asks for confirmation, then removes the items", %{conn: conn} do
      page = draft_page(%{title: "DeleteMe"})

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      lv |> element(~s(input[phx-value-key="page:#{page.id}"])) |> render_click()

      # First click only opens the guard; nothing is deleted yet. The copy is
      # honest about soft-delete (audit U-M1): trash, restorable for 30 days.
      confirm_html = lv |> element("button[phx-value-action='delete']") |> render_click()
      assert confirm_html =~ "to trash"
      assert confirm_html =~ "30 days"
      assert Enum.any?(CMS.list_pages!(authorize?: false), &(&1.id == page.id))

      # Confirming performs the delete.
      lv |> element("button[phx-click='confirm_bulk']") |> render_click()
      refute Enum.any?(CMS.list_pages!(authorize?: false), &(&1.id == page.id))
    end

    test "cancelling the guard dismisses it without deleting", %{conn: conn} do
      page = draft_page()

      {:ok, lv, _html} = conn |> log_in(authed_user(:admin)) |> live(~p"/editor")

      lv |> element(~s(input[phx-value-key="page:#{page.id}"])) |> render_click()
      lv |> element("button[phx-value-action='delete']") |> render_click()
      cancelled = lv |> element("button[phx-click='cancel_bulk']") |> render_click()

      refute cancelled =~ "to trash?"
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

  # Audit U-M3: filter/search state lives in the URL, so refresh/back/share
  # keep it and changing it patches the URL.
  describe "filter state in the URL" do
    test "mounting with query params restores the status and search filters", %{conn: conn} do
      draft_page(%{title: "OnlyDraft"})
      draft_page(%{title: "LivePage", state: :published})

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor?status=published&q=live")

      assert html =~ "LivePage"
      refute html =~ "OnlyDraft"
      assert html =~ ~s(value="live")
    end

    test "changing the filter patches the URL", %{conn: conn} do
      draft_page()

      {:ok, lv, _html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      lv |> form("#content-filter", %{status: "draft"}) |> render_change()
      assert_patch(lv, ~p"/editor?status=draft")
    end
  end

  # Audit U-M4: a saved schedule was invisible after saving — the editor header
  # and content list now carry a "Scheduled" badge with a localized <time>.
  describe "scheduled publish visibility" do
    test "the list and the editor show a scheduled badge for a scheduled draft", %{conn: conn} do
      at = DateTime.add(DateTime.utc_now(), 3600, :second)
      page = draft_page(%{title: "SoonLive", scheduled_at: at})

      {:ok, _lv, list_html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")
      assert list_html =~ ~s(id="scheduled-page-#{page.id}")
      assert list_html =~ ~s(phx-hook="LocalTime")

      {:ok, _lv, editor_html} =
        build_conn() |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      assert editor_html =~ "Scheduled to publish"
      assert editor_html =~ ~s(id="scheduled-publish-badge")
      # The schedule input is the local/UTC hook pair, labelled with the tz.
      assert editor_html =~ ~s(phx-hook="UtcDatetimeInput")
      assert editor_html =~ "Shown in your local timezone; stored as UTC."
    end
  end

  # Audit U-H2: ApplyCustomFields errors land on :custom_fields and previously
  # rendered nowhere — the editor got a generic flash with nothing highlighted.
  describe "custom field validation errors" do
    test "an invalid custom-field value renders an inline error and opens the section",
         %{conn: conn} do
      KilnCMS.CMS.create_field_definition!(
        %{content_type: :page, name: "level", label: "Level", field_type: :integer},
        actor: authed_user(:admin)
      )

      page = draft_page(%{title: "Has fields"})

      {:ok, lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # The input is labelled via for/id (previously a bare sibling label).
      assert html =~ ~s(for="custom-field-level")
      assert html =~ ~s(id="custom-field-level")

      invalid =
        lv
        |> form("#page-editor", form: %{custom_fields: %{level: "abc"}})
        |> render_submit()

      assert invalid =~ "Level (level) must be a whole number"
      assert invalid =~ ~s(id="custom-field-level-errors")
      assert invalid =~ ~s(aria-invalid="true")
      # The collapsed "Custom fields" details opens so the error is visible.
      assert invalid =~ ~r/<details[^>]*open/
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

    # T2.4: creating a translation navigates away, killing the debounced autosave
    # timer — it must flush the pending draft edit first so it isn't lost.
    test "creating a translation flushes the source draft's pending edits", %{conn: conn} do
      page = draft_page(%{title: "Original"})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # A dirty edit schedules (but hasn't fired) the debounced autosave.
      lv |> form("#page-editor", form: %{title: "Edited before translating"}) |> render_change()
      assert CMS.get_page!(page.id, authorize?: false).title == "Original"

      # Creating a translation navigates away; the pending edit must be saved.
      render_hook(lv, "create_translation", %{"locale" => "fr"})

      assert CMS.get_page!(page.id, authorize?: false).title == "Edited before translating"
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
      send(lv.pid, :snapshot)
      render(lv)

      # The published record is only changed via the explicit Save button.
      assert CMS.get_page!(page.id, authorize?: false).title == "Live"
    end
  end

  # T2 crash recovery: non-draft content isn't applied to live automatically,
  # but its working state is snapshotted so a crash/reconnect can recover it.
  describe "crash-recovery snapshot" do
    test "editing published content snapshots the working state, live untouched",
         %{conn: conn} do
      page = draft_page(%{title: "Live", state: :published})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> form("#page-editor", form: %{title: "Working edit"}) |> render_change()
      send(lv.pid, :snapshot)
      render(lv)

      reloaded = CMS.get_page!(page.id, authorize?: false)
      # Live content + state untouched...
      assert reloaded.title == "Live"
      assert reloaded.state == :published
      # ...but the edit is recoverable.
      assert reloaded.draft_snapshot["title"] == "Working edit"
      assert reloaded.draft_saved_at
    end

    test "reopening offers to restore, and restoring loads the snapshot", %{conn: conn} do
      page = draft_page(%{title: "Live", state: :published})

      # A prior session's leftover working snapshot.
      page
      |> Ash.Changeset.for_update(:snapshot_draft, %{draft_snapshot: %{"title" => "Recovered"}},
        authorize?: false
      )
      |> Ash.update!()

      {:ok, lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      assert html =~ "unsaved changes from a previous session"

      restored = lv |> element("button[phx-click='restore_draft']") |> render_click()
      # The form now shows the recovered title, and the banner is gone.
      assert restored =~ "Recovered"
      refute restored =~ "unsaved changes from a previous session"
      # Live content still not changed until an explicit save.
      assert CMS.get_page!(page.id, authorize?: false).title == "Live"
    end

    test "discarding clears the snapshot", %{conn: conn} do
      page = draft_page(%{title: "Live", state: :published})

      page
      |> Ash.Changeset.for_update(:snapshot_draft, %{draft_snapshot: %{"title" => "Recovered"}},
        authorize?: false
      )
      |> Ash.update!()

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> element("button[phx-click='discard_draft']") |> render_click()

      reloaded = CMS.get_page!(page.id, authorize?: false)
      assert reloaded.draft_snapshot == nil
      assert reloaded.draft_saved_at == nil
    end

    test "an explicit save clears any recovery snapshot", %{conn: conn} do
      page = draft_page(%{title: "Draft", state: :draft})

      page
      |> Ash.Changeset.for_update(:snapshot_draft, %{draft_snapshot: %{"title" => "Stale"}},
        authorize?: false
      )
      |> Ash.update!()

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> form("#page-editor", form: %{title: "Saved"}) |> render_submit()

      reloaded = CMS.get_page!(page.id, authorize?: false)
      assert reloaded.title == "Saved"
      assert reloaded.draft_snapshot == nil
    end

    # Audit U-H1: non-draft content gets no autosave, so unsaved edits must be
    # tracked — the form flips data-dirty (read by the UnsavedGuard hook) and
    # shows an "Unsaved changes" indicator until an explicit Save.
    test "editing published content marks the form dirty until saved", %{conn: conn} do
      page = draft_page(%{title: "Live", state: :published})

      {:ok, lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      assert html =~ ~s(data-dirty="false")

      changed = lv |> form("#page-editor", form: %{title: "Edited live"}) |> render_change()
      assert changed =~ ~s(data-dirty="true")
      assert changed =~ "Unsaved changes"

      saved = lv |> form("#page-editor", form: %{title: "Edited live"}) |> render_submit()
      assert saved =~ ~s(data-dirty="false")
      refute saved =~ "Unsaved changes"
      assert CMS.get_page!(page.id, authorize?: false).title == "Edited live"
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

  # Audit theme 4: client-supplied index params must never crash the LiveView.
  # A garbled or out-of-range "index" used to hit String.to_integer/Enum.at
  # unguarded; now every such event is a no-op that keeps the session alive.
  describe "block index guards (audit theme 4)" do
    test "a non-numeric move_block index is a no-op, not a crash", %{conn: conn} do
      page = draft_page(%{title: "Guarded"})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # Garbage index — the LV survives and stays rendered.
      render_hook(lv, "move_block", %{"index" => "nope", "dir" => "up"})
      assert render(lv) =~ "Guarded"
    end

    test "an out-of-range move_block index does not swap the wrong blocks", %{conn: conn} do
      page = draft_page(%{title: "Bounds"})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      # A wildly out-of-range and a negative index both no-op rather than
      # resolving to the last element via Enum.at/-1.
      render_hook(lv, "move_block", %{"index" => "9999", "dir" => "down"})
      render_hook(lv, "move_block", %{"index" => "-1", "dir" => "up"})
      assert render(lv) =~ "Bounds"
    end

    test "a non-numeric open_picker index is a no-op, not a crash", %{conn: conn} do
      page = draft_page(%{title: "Picker"})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      render_hook(lv, "open_picker", %{"index" => "boom"})
      assert render(lv) =~ "Picker"
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

      lv |> element("button[phx-click='restore'][phx-value-id='#{page.id}']") |> render_click()

      # Gone from trash, back in the main listing.
      refute render(lv) =~ "TrashedPage"
      assert Enum.any?(CMS.list_pages!(authorize?: false), &(&1.id == page.id))
    end

    # #167: admins can permanently delete a single trashed item (not just empty all).
    test "admin permanently deletes a single trashed item", %{conn: conn} do
      page = draft_page(%{title: "PurgeOne"})
      admin = authed_user(:admin)
      :ok = CMS.destroy_page(page, actor: admin)

      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/trash")
      assert html =~ "PurgeOne"
      assert html =~ "Delete permanently"

      lv |> element("button[phx-click='purge'][phx-value-id='#{page.id}']") |> render_click()

      # Hard-deleted: gone from trash AND not back in the listing (i.e. not just
      # restored).
      refute render(lv) =~ "PurgeOne"
      refute Enum.any?(CMS.list_pages!(authorize?: false), &(&1.id == page.id))
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
    # #154: the featured image uses the searchable media picker, not a <select>.
    test "selects the featured image via the media picker", %{conn: conn} do
      media = Ash.Seed.seed!(MediaItem, %{filename: "feat.jpg", url: "/uploads/feat"})
      page = draft_page(%{title: "FeatPage"})

      {:ok, lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      assert html =~ "Choose from library"

      lv |> element("button[phx-click='open_featured_picker']") |> render_click()

      lv
      |> element("button[phx-click='pick_image'][phx-value-id='#{media.id}']")
      |> render_click()

      lv |> form("#page-editor") |> render_submit()

      assert CMS.get_page!(page.id, authorize?: false).featured_image_id == media.id
    end

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

    test "the editor broadcasts preview updates on change while a window is open", %{conn: conn} do
      page = draft_page()
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, PreviewLive.topic("page", page.id))
      # Simulate an open pop-out window (PreviewLive tracks itself like this).
      KilnCMSWeb.Presence.track_preview(self(), "page", page.id)

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> form("#page-editor", form: %{title: "Broadcasted"}) |> render_change()

      assert_receive {:preview_update, %{title: "Broadcasted"}}
    end

    # Audit P-M2: without an open preview window there's nobody to receive the
    # payload, so the editor skips building/broadcasting it per keystroke.
    test "no preview broadcast is built when no window is open", %{conn: conn} do
      page = draft_page()
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, PreviewLive.topic("page", page.id))

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> form("#page-editor", form: %{title: "Unheard"}) |> render_change()

      refute_receive {:preview_update, _}, 100
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
      KilnCMSWeb.Presence.track_preview(self(), "page", page.id)

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

    test "assigns a category and tags on save", %{conn: conn} do
      post = draft_post()
      cat = Ash.Seed.seed!(Category, %{name: "News", slug: "c-#{uniq()}"})
      tag = Ash.Seed.seed!(Tag, %{name: "elixir", slug: "t-#{uniq()}"})

      {:ok, lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/posts/#{post.id}")

      # The seeded taxonomy appears as options (the featured image is chosen
      # through the media picker modal rather than a <select> — see #154).
      assert html =~ "News"
      assert html =~ "elixir"

      lv
      |> form("#post-editor", form: %{category_id: cat.id, tag_ids: [tag.id]})
      |> render_submit()

      saved = CMS.get_post!(post.id, authorize?: false, load: [:tags])
      assert saved.category_id == cat.id
      assert [%{id: tag_id}] = saved.tags
      assert tag_id == tag.id
    end

    test "an existing tag link is pre-selected in the picker", %{conn: conn} do
      tag = Ash.Seed.seed!(Tag, %{name: "preselected", slug: "t-#{uniq()}"})
      editor = authed_user(:editor)

      post =
        CMS.create_post!(%{title: "T", slug: "p-#{uniq()}", tag_ids: [tag.id]}, actor: editor)

      {:ok, _lv, html} = conn |> log_in(editor) |> live(~p"/editor/posts/#{post.id}")

      # The tag's checkbox is pre-checked even before the user touches the field
      # (so an untouched save won't wipe the link) — #153 replaced the <select>.
      assert html =~
               ~r/<input[^>]*value="#{tag.id}"[^>]*checked|checked[^>]*value="#{tag.id}"/
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

    test "many content types collapse the New buttons into one dropdown", %{conn: conn} do
      admin = authed_user(:admin)

      for label <- ~w(Recipe Review) do
        CMS.create_type_definition!(
          %{name: "#{String.downcase(label)}#{System.unique_integer([:positive])}", label: label},
          actor: admin
        )
      end

      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor")

      # page + post + 2 dynamic types crosses the inline threshold: one summary
      # trigger, with the per-type buttons inside the menu still wired to "new".
      assert html =~ "content-new-menu"
      assert html =~ "New recipe"

      {:error, {:live_redirect, %{to: to}}} =
        lv |> element(~s(#content-new-menu button[phx-value-kind="page"])) |> render_click()

      assert to =~ "/editor/content/page/"
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

  # Regression for #133: every authoring LiveView must pass current_user to the
  # layout so the console shell shows the authenticated nav (Sign out + sidebar
  # sections like Media / Settings) instead of Sign in while the editor works.
  describe "header navigation (current_user in layout)" do
    test "content list shows authenticated nav for a signed-in editor", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      assert html =~ "Sign out"
      refute html =~ ~r/>\s*Sign in\s*</
      assert html =~ "Media"
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

    # #150: the two slash systems have distinct hints (block inserter vs in-text).
    test "distinguishes the block inserter from the rich-text slash menu", %{conn: conn} do
      page =
        draft_page(%{
          title: "SlashPage",
          blocks: [%{type: :rich_text, content: "<p>x</p>", order: 0}]
        })

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/content/page/#{page.id}")

      assert html =~ "Type / for text formatting within this block."
      assert html =~ "Add block"
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

    # #181: the Preview link opens in a new tab safely and warns assistive tech.
    test "the new-tab Preview link is safe and labeled", %{conn: conn} do
      page = draft_page(%{title: "NewTabPage"})

      {:ok, _lv, html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/content/page/#{page.id}")

      assert html =~ ~r/target="_blank"[^>]*rel="noopener noreferrer"/
      assert html =~ "(opens in a new tab)"
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

  describe "status trigram glyphs" do
    # The list's composite status glyph is a trigram: published (bottom line),
    # a variant in every configured locale (middle), a pending scheduled
    # transition (top). The trigram's name is in the accessible label.
    test "a bare draft renders as kun (all yin)", %{conn: conn} do
      draft_page(%{title: "Bare draft"})

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      assert html =~ "kun · earth · not published · translation gaps · no schedule"
    end

    test "published, fully translated and scheduled renders as qian (all yang)", %{conn: conn} do
      slug = "qi-#{System.unique_integer([:positive])}"
      horizon = DateTime.add(DateTime.utc_now(), 3, :day)

      for locale <- ["en", "fr", "es"] do
        draft_page(%{slug: slug, locale: locale, state: :published, unpublish_at: horizon})
      end

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      assert html =~ "qian · heaven · published · translated · scheduled"
    end

    test "published but untranslated and unscheduled renders as zhen", %{conn: conn} do
      draft_page(%{title: "Solo published", state: :published})

      {:ok, _lv, html} = conn |> log_in(authed_user(:editor)) |> live(~p"/editor")

      assert html =~ "zhen · thunder · published · translation gaps · no schedule"
    end
  end

  # Nested-layout container editing (#335): add a columns block, nest child blocks
  # inside its columns, and persist the tree through save.
  describe "columns (nested-layout) block editor" do
    defp add_columns_block(lv) do
      lv
      |> element("button[data-inserter-item][phx-value-type='columns']")
      |> render_click()
    end

    # The stable id of the (single) columns block currently in the editor DOM.
    defp columns_block_id(lv) do
      [_, id] = Regex.run(~r/data-block-id="([^"]+)"/, render(lv))
      id
    end

    test "columns is offered in the block inserter", %{conn: conn} do
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      assert has_element?(lv, "button[data-inserter-item][phx-value-type='columns']")
    end

    test "adding a columns block renders a two-column nested editor", %{conn: conn} do
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      add_columns_block(lv)

      id = columns_block_id(lv)
      # Two columns, each with an "add block" palette entry per child type.
      assert has_element?(
               lv,
               "button[phx-click='col_add_child'][phx-value-col='0'][phx-value-type='heading']"
             )

      assert has_element?(
               lv,
               "button[phx-click='col_add_child'][phx-value-col='1'][phx-value-type='heading']"
             )

      assert has_element?(lv, "button[phx-click='col_add_column'][phx-value-id='#{id}']")
    end

    test "an empty columns block persists on save", %{conn: conn} do
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      add_columns_block(lv)
      lv |> form("#page-editor") |> render_submit()

      assert [block] = blocks_legacy(CMS.get_page!(page.id, authorize?: false))
      assert block.type == :columns
      assert length(block.data["columns"]) == 2
    end

    test "a nested child block persists with its edited text", %{conn: conn} do
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      add_columns_block(lv)
      id = columns_block_id(lv)

      # Add a heading child to the first column.
      lv
      |> element("button[phx-click='col_add_child'][phx-value-col='0'][phx-value-type='heading']")
      |> render_click()

      # The child now has a stable id; edit its text through the socket-side event.
      [_, child_id] = Regex.run(~r/data-child-id="([^"]+)"/, render(lv))

      render_hook(lv, "col_update_child", %{
        "id" => id,
        "child" => child_id,
        "field" => "text",
        "value" => "Nested heading"
      })

      lv |> form("#page-editor") |> render_submit()

      assert [block] = blocks_legacy(CMS.get_page!(page.id, authorize?: false))
      assert block.type == :columns
      assert [%{"blocks" => [child]}, %{"blocks" => []}] = block.data["columns"]
      assert child["_type"] == "heading"
      assert child["text"] == "Nested heading"
    end

    test "a featured-image change keeps columns children (T1.2 regression)", %{conn: conn} do
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      add_columns_block(lv)
      id = columns_block_id(lv)

      lv
      |> element("button[phx-click='col_add_child'][phx-value-col='0'][phx-value-type='heading']")
      |> render_click()

      [_, child_id] = Regex.run(~r/data-child-id="([^"]+)"/, render(lv))

      render_hook(lv, "col_update_child", %{
        "id" => id,
        "child" => child_id,
        "field" => "text",
        "value" => "Keep me"
      })

      # A featured-image change re-validates the form from its params. It must
      # go through the child-injection path, or it wipes the socket-managed
      # columns children before the save (docs/audit-content-editor.md T1.2).
      render_hook(lv, "clear_featured", %{})

      lv |> form("#page-editor") |> render_submit()

      assert [block] = blocks_legacy(CMS.get_page!(page.id, authorize?: false))
      assert [%{"blocks" => [child]}, %{"blocks" => []}] = block.data["columns"]
      assert child["text"] == "Keep me"
    end

    test "a reorder that omits a just-added child keeps it (T1.4 regression)", %{conn: conn} do
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      add_columns_block(lv)
      id = columns_block_id(lv)

      # Two heading children in column 0.
      for _ <- 1..2 do
        lv
        |> element(
          "button[phx-click='col_add_child'][phx-value-col='0'][phx-value-type='heading']"
        )
        |> render_click()
      end

      child_ids =
        ~r/data-child-id="([^"]+)"/
        |> Regex.scan(render(lv))
        |> Enum.map(fn [_, cid] -> cid end)

      assert length(child_ids) == 2
      [first_child | _] = child_ids

      # A stale nested-drag payload mentioning only the FIRST child (the second
      # was added after the DOM snapshot). The omitted child must survive.
      render_hook(lv, "col_reorder", %{"id" => id, "cols" => [[first_child], []]})

      lv |> form("#page-editor") |> render_submit()

      assert [block] = blocks_legacy(CMS.get_page!(page.id, authorize?: false))
      [%{"blocks" => col0}, _] = block.data["columns"]
      assert Enum.sort(Enum.map(col0, & &1["id"])) == Enum.sort(child_ids)
    end

    test "the nested block renders in the live preview", %{conn: conn} do
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      add_columns_block(lv)
      id = columns_block_id(lv)

      lv
      |> element("button[phx-click='col_add_child'][phx-value-col='0'][phx-value-type='heading']")
      |> render_click()

      [_, child_id] = Regex.run(~r/data-child-id="([^"]+)"/, render(lv))

      html =
        render_hook(lv, "col_update_child", %{
          "id" => id,
          "child" => child_id,
          "field" => "text",
          "value" => "PreviewNested"
        })

      # The inline preview renders through the typed serializers (columns → grid).
      assert html =~ "PreviewNested"
      assert html =~ "kiln-columns"
    end
  end

  # GEO blocks (#357): faq/how_to item rows are bound inputs normalized from
  # indexed maps; claim edits ride the generic DSL field editor.
  describe "GEO block editing" do
    test "faq, how_to and claim are offered in the block inserter", %{conn: conn} do
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      for type <- ~w(faq how_to claim) do
        assert has_element?(lv, "button[data-inserter-item][phx-value-type='#{type}']")
      end
    end

    test "faq rows add, edit and persist through save", %{conn: conn} do
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> element("button[data-inserter-item][phx-value-type='faq']") |> render_click()

      # Add one Q&A row, then type into its bound inputs.
      lv
      |> element("button[phx-click='geo_item_add'][phx-value-index='0']")
      |> render_click()

      lv
      |> form("#page-editor")
      |> render_change(%{
        "form" => %{
          "blocks" => %{
            "0" => %{
              "title" => "FAQ",
              "items" => %{"0" => %{"question" => "What?", "answer" => "This."}}
            }
          }
        }
      })

      lv |> form("#page-editor") |> render_submit()

      assert [block] = blocks_legacy(CMS.get_page!(page.id, authorize?: false))
      assert block.type == :faq
      assert block.content == "FAQ"
      assert block.data["items"] == [%{"question" => "What?", "answer" => "This."}]
    end

    test "removing the last faq row clears the stored list", %{conn: conn} do
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> element("button[data-inserter-item][phx-value-type='faq']") |> render_click()

      lv
      |> element("button[phx-click='geo_item_add'][phx-value-index='0']")
      |> render_click()

      lv
      |> element("button[phx-click='geo_item_remove'][phx-value-index='0'][phx-value-item='0']")
      |> render_click()

      lv |> form("#page-editor") |> render_submit()

      assert [block] = blocks_legacy(CMS.get_page!(page.id, authorize?: false))
      assert block.type == :faq
      assert block.data["items"] == []
    end

    test "a claim block persists its citation fields via the DSL editor", %{conn: conn} do
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> element("button[data-inserter-item][phx-value-type='claim']") |> render_click()

      lv
      |> form("#page-editor")
      |> render_change(%{
        "form" => %{
          "blocks" => %{
            "0" => %{
              "text" => "Water is wet.",
              "source_title" => "Src",
              "source_url" => "https://s.example",
              "rating" => ""
            }
          }
        }
      })

      lv |> form("#page-editor") |> render_submit()

      assert [block] = blocks_legacy(CMS.get_page!(page.id, authorize?: false))
      assert block.type == :claim
      assert block.content == "Water is wet."
      assert block.data["source_title"] == "Src"
      assert block.data["source_url"] == "https://s.example"
    end

    test "how_to steps persist and render in the preview", %{conn: conn} do
      page = draft_page(%{blocks: []})

      {:ok, lv, _html} =
        conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

      lv |> element("button[data-inserter-item][phx-value-type='how_to']") |> render_click()

      lv
      |> element("button[phx-click='geo_item_add'][phx-value-index='0']")
      |> render_click()

      html =
        lv
        |> form("#page-editor")
        |> render_change(%{
          "form" => %{
            "blocks" => %{
              "0" => %{
                "name" => "Brew tea",
                "steps" => %{"0" => %{"name" => "Boil", "text" => "Boil water."}}
              }
            }
          }
        })

      assert html =~ "kiln-howto"

      lv |> form("#page-editor") |> render_submit()

      assert [block] = blocks_legacy(CMS.get_page!(page.id, authorize?: false))
      assert block.type == :how_to
      assert block.content == "Brew tea"
      assert block.data["steps"] == [%{"name" => "Boil", "text" => "Boil water."}]
    end
  end
end
