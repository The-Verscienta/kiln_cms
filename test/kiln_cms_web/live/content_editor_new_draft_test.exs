defmodule KilnCMSWeb.ContentEditorNewDraftTest do
  @moduledoc """
  "New page" opens the editor on an unsaved document at
  `/editor/content/:type/new`. Nothing is written until the writer commits —
  a non-blank title or Save — and then exactly one row is created, through the
  same create action and authorization as before, and the same LiveView
  carries on at `/editor/content/:type/:id` (a patch, not a remount).
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.ContentTypes

  @password "password123456"

  defp authed_user(role, attrs \\ %{}) do
    email = "new-draft-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )

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

  defp pages(actor), do: ContentTypes.list!("page", actor: actor)

  defp type_title(lv, title) do
    render_change(lv, "validate", %{"form" => %{"title" => title}, "_target" => ["form", "title"]})
  end

  setup %{conn: conn} do
    editor = authed_user(:editor)
    %{conn: log_in(conn, editor), editor: editor}
  end

  test "New on the content list opens the unsaved editor without writing a row",
       %{conn: conn, editor: editor} do
    {:ok, index, _html} = live(conn, ~p"/editor")

    assert {:error, {:live_redirect, %{to: "/editor/content/page/new"}}} =
             index
             |> element(~s{button[phx-click="new"][phx-value-kind="page"]})
             |> render_click()

    assert pages(editor) == []
  end

  test "visiting /new creates nothing, and says when it will", %{conn: conn, editor: editor} do
    {:ok, lv, html} = live(conn, ~p"/editor/content/page/new")

    assert html =~ "New page"
    assert has_element?(lv, ~s{form#page-editor input[name="form[title]"]})
    assert has_element?(lv, "#new-draft-status")
    # No id-bound features on a document that does not exist yet.
    refute has_element?(lv, ~s{button[phx-click="duplicate"]})
    refute has_element?(lv, ~s{[role="tablist"]})

    # Leaving (browser back, closing the tab) is just the process ending.
    assert pages(editor) == []
  end

  test "a blank title is not a commit", %{conn: conn, editor: editor} do
    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/new")

    type_title(lv, "   ")

    assert pages(editor) == []
    assert has_element?(lv, "#new-draft-status")
  end

  test "the first title keystroke creates exactly one row and patches to its edit route",
       %{conn: conn, editor: editor} do
    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/new")

    type_title(lv, "Hello kiln")

    assert [page] = pages(editor)
    assert_patch(lv, ~p"/editor/content/page/#{page.id}")

    # The same LiveView carried on into the full editor with the typed title,
    # and the scaffold slug re-derived from it.
    assert has_element?(lv, ~s{input[name="form[title]"][value="Hello kiln"]})
    assert has_element?(lv, ~s{input[name="form[slug]"][value="hello-kiln"]})
    assert has_element?(lv, ~s{[role="tablist"]})
    refute has_element?(lv, "#new-draft-status")
    assert has_element?(lv, ~s{form#page-editor[data-dirty="true"]})
  end

  test "rapid changes after the first create no second row", %{conn: conn, editor: editor} do
    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/new")

    type_title(lv, "H")
    type_title(lv, "He")
    type_title(lv, "Hel")

    assert [page] = pages(editor)
    assert_patch(lv, ~p"/editor/content/page/#{page.id}")
    assert has_element?(lv, ~s{input[name="form[title]"][value="Hel"]})
  end

  test "Save on a blank new document creates the untitled draft", %{conn: conn, editor: editor} do
    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/new")

    # The title is `required`, and a real browser runs constraint validation
    # before firing the submit: without `formnovalidate` on Save draft, a blank
    # title makes the button do nothing at all. `render_submit/1` below skips
    # browser validation, so it cannot see that. Pin the attribute instead
    # (#1497: every e2e spec that opened a new draft timed out on this).
    assert has_element?(lv, ~s{form#page-editor input[name="form[title]"][required]})

    assert has_element?(
             lv,
             ~s{form#page-editor button#new-draft-save[type="submit"][formnovalidate]}
           )

    html = lv |> form("#page-editor", %{"form" => %{"title" => ""}}) |> render_submit()

    assert [page] = pages(editor)
    assert page.title == "Untitled page"
    assert page.slug =~ ~r/^untitled-/
    assert_patch(lv, ~p"/editor/content/page/#{page.id}")
    assert html =~ "Saved."
  end

  test "Save with a title creates the row and saves the title", %{conn: conn, editor: editor} do
    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/new")

    lv |> form("#page-editor", %{"form" => %{"title" => "Saved at once"}}) |> render_submit()

    assert [page] = pages(editor)
    assert_patch(lv, ~p"/editor/content/page/#{page.id}")
    saved = ContentTypes.get_record!("page", page.id, actor: editor)
    assert saved.title == "Saved at once"
    # Derived from the saved title, stop words stripped — the slug a writer
    # typing the same title would have got.
    assert saved.slug == "saved-once"
  end

  test "an editor who may not author the type is refused at the door, and nothing is written",
       %{conn: conn} do
    # Scoped to author posts only: pages are not offered on the content list,
    # and the create policy (`Checks.EditableContentType`) refuses them.
    post_only = authed_user(:editor, %{editable_types: ["post"]})
    conn = log_in(conn, post_only)

    {:ok, index, html} = live(conn, ~p"/editor")
    refute html =~ ~s{phx-value-kind="page"}
    _ = index

    assert {:error, {:live_redirect, %{to: "/editor", flash: flash}}} =
             live(conn, ~p"/editor/content/page/new")

    assert flash["error"] =~ "can't create"
    assert pages(authed_user(:admin)) == []
  end

  test "an unknown type goes back to the content list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/editor"}}} =
             live(conn, ~p"/editor/content/no-such-type/new")
  end

  # `?scheduled_at=` is what the calendar's "new on this day" picker sends.
  describe "?scheduled_at= (#1812)" do
    defp in_days(days) do
      Date.utc_today() |> Date.add(days) |> DateTime.new!(~T[09:00:00], "Etc/UTC")
    end

    defp new_page_path(scheduled_at),
      do: ~p"/editor/content/page/new?#{[scheduled_at: scheduled_at]}"

    setup %{conn: conn} do
      admin = authed_user(:admin)
      %{conn: log_in(conn, admin), admin: admin}
    end

    test "a future date is shown, and the draft is created with it", %{conn: conn, admin: admin} do
      at = in_days(10)
      {:ok, lv, html} = live(conn, new_page_path(DateTime.to_iso8601(at)))

      assert has_element?(lv, "#new-draft-scheduled-at")
      assert html =~ "Scheduled to publish on #{Calendar.strftime(at, "%-d %B %Y")} at 09:00 UTC"
      assert pages(admin) == []

      type_title(lv, "Planned launch")

      assert [page] = pages(admin)
      assert_patch(lv, ~p"/editor/content/page/#{page.id}")
      assert DateTime.compare(page.scheduled_at, at) == :eq

      # …and the full editor's schedule field now carries it.
      assert has_element?(
               lv,
               ~s{input[name="form[scheduled_at]"][value^="#{Date.to_iso8601(DateTime.to_date(at))}"]}
             )
    end

    test "an editor on a site that lets editors publish keeps the date", %{editor: editor} do
      {:ok, _} =
        KilnCMS.CMS.EditorialSettings.save(%{editors_can_publish: true},
          actor: authed_user(:admin),
          tenant: KilnCMS.Accounts.default_org_id()
        )

      at = in_days(4)
      conn = log_in(build_conn(), editor)
      {:ok, lv, _html} = live(conn, new_page_path(DateTime.to_iso8601(at)))

      assert has_element?(lv, "#new-draft-scheduled-at")
      type_title(lv, "Editor planned")

      assert [page] = pages(editor)
      assert DateTime.compare(page.scheduled_at, at) == :eq
    end

    test "Save draft also keeps the date", %{conn: conn, admin: admin} do
      at = in_days(3)
      {:ok, lv, _html} = live(conn, new_page_path(DateTime.to_iso8601(at)))

      lv |> form("#page-editor", form: %{title: ""}) |> render_submit()

      assert [page] = pages(admin)
      assert DateTime.compare(page.scheduled_at, at) == :eq
    end

    for {label, value} <- [
          {"garbage", "next-tuesday"},
          {"a bare date", "2099-01-01"},
          {"an empty value", ""}
        ] do
      test "#{label} is ignored and the draft is unscheduled", %{conn: conn, admin: admin} do
        {:ok, lv, _html} = live(conn, new_page_path(unquote(value)))

        refute has_element?(lv, "#new-draft-scheduled-at")
        type_title(lv, "Unscheduled")

        assert [%{scheduled_at: nil}] = pages(admin)
      end
    end

    test "a time already past is ignored", %{conn: conn, admin: admin} do
      {:ok, lv, _html} = live(conn, new_page_path(DateTime.to_iso8601(in_days(-2))))

      refute has_element?(lv, "#new-draft-scheduled-at")
      type_title(lv, "Too late")

      assert [%{scheduled_at: nil}] = pages(admin)
    end
  end

  # An editor on a site where only admins publish may not set `scheduled_at`;
  # their date becomes a PROPOSAL an admin confirms.
  describe "a proposed publish date (#1812)" do
    defp proposal_in(days) do
      Date.utc_today() |> Date.add(days) |> DateTime.new!(~T[09:00:00], "Etc/UTC")
    end

    defp page_by(actor, id), do: ContentTypes.get_record!("page", id, actor: actor)

    test "an editor who may not publish lands with a proposed date, and it is persisted",
         %{conn: conn, editor: editor} do
      at = proposal_in(5)

      {:ok, lv, html} =
        live(conn, ~p"/editor/content/page/new?#{[scheduled_at: DateTime.to_iso8601(at)]}")

      assert has_element?(lv, ~s{#new-draft-scheduled-at[data-date-kind="proposed_publish_at"]})
      assert html =~ "an admin confirms the date"

      type_title(lv, "Editor proposal")

      assert [page] = pages(editor)
      assert_patch(lv, ~p"/editor/content/page/#{page.id}")
      assert page.scheduled_at == nil
      assert DateTime.compare(page.proposed_publish_at, at) == :eq

      # The full editor shows it in the schedule area, editable by the author,
      # with the real publish date still closed to them.
      assert has_element?(
               lv,
               ~s{input[type="hidden"][name="form[proposed_publish_at]"][value^="#{Date.to_iso8601(DateTime.to_date(at))}"]}
             )

      assert has_element?(lv, ~s{input[data-local-input][id^="scheduled-at-local"][disabled]})
    end

    test "the author can move their proposal, but a forged scheduled_at is refused",
         %{editor: editor} do
      page =
        ContentTypes.create!("page", %{title: "Mine", proposed_publish_at: proposal_in(5)},
          actor: editor
        )

      moved = proposal_in(9)

      assert {:ok, %{proposed_publish_at: stored}} =
               ContentTypes.update("page", page, %{proposed_publish_at: moved}, actor: editor)

      assert DateTime.compare(stored, moved) == :eq

      assert {:error, %Ash.Error.Forbidden{}} =
               ContentTypes.update("page", page_by(editor, page.id), %{scheduled_at: moved},
                 actor: editor
               )

      assert page_by(editor, page.id).scheduled_at == nil
    end

    test "an admin confirms it from the review queue: scheduled, proposal cleared",
         %{conn: conn, editor: editor} do
      at = proposal_in(6)

      page =
        ContentTypes.create!("page", %{title: "Ask", proposed_publish_at: at}, actor: editor)

      {:ok, page} = ContentTypes.transition("page", "submit", page, actor: editor)

      # The editor sees the proposal on their row but cannot confirm it.
      {:ok, own, _html} = live(conn, ~p"/editor?status=in_review")
      assert has_element?(own, "#proposed-page-#{page.id}")
      refute has_element?(own, ~s{button[phx-click="confirm_proposed_date"]})

      admin = authed_user(:admin)
      {:ok, queue, _html} = live(log_in(build_conn(), admin), ~p"/editor?status=in_review")

      # The reviewer sees the proposed date on the submitted row.
      assert queue |> element("#proposed-page-#{page.id}") |> render() =~
               Calendar.strftime(at, "%Y-%m-%d %H:%M")

      html =
        queue
        |> element(~s{button[phx-click="confirm_proposed_date"][phx-value-id="#{page.id}"]})
        |> render_click()

      assert html =~ "Scheduled to publish on"
      confirmed = page_by(admin, page.id)
      assert DateTime.compare(confirmed.scheduled_at, at) == :eq
      assert confirmed.proposed_publish_at == nil
      refute has_element?(queue, "#proposed-page-#{page.id}")
    end

    test "a forged confirm from an editor who may not publish changes nothing",
         %{conn: conn, editor: editor} do
      page =
        ContentTypes.create!("page", %{title: "Forged", proposed_publish_at: proposal_in(4)},
          actor: editor
        )

      {:ok, lv, _html} = live(conn, ~p"/editor")

      html = render_click(lv, "confirm_proposed_date", %{"kind" => "page", "id" => page.id})

      assert html =~ "can&#39;t set the publish date"
      reloaded = page_by(editor, page.id)
      assert reloaded.scheduled_at == nil
      refute reloaded.proposed_publish_at == nil
    end

    test "setting any publish date, or publishing, clears the proposal", %{editor: editor} do
      admin = authed_user(:admin)

      scheduled =
        ContentTypes.create!("page", %{title: "A", proposed_publish_at: proposal_in(3)},
          actor: editor
        )

      {:ok, scheduled} =
        ContentTypes.update("page", scheduled, %{scheduled_at: proposal_in(8)}, actor: admin)

      assert scheduled.proposed_publish_at == nil

      published =
        ContentTypes.create!("page", %{title: "B", proposed_publish_at: proposal_in(3)},
          actor: editor
        )

      {:ok, published} = ContentTypes.transition("page", "publish", published, actor: admin)
      assert published.proposed_publish_at == nil

      # An edit that leaves `scheduled_at` alone keeps the proposal.
      kept =
        ContentTypes.create!("page", %{title: "C", proposed_publish_at: proposal_in(3)},
          actor: editor
        )

      {:ok, kept} = ContentTypes.update("page", kept, %{title: "C2"}, actor: admin)
      refute kept.proposed_publish_at == nil
    end

    test "an admin's editor offers the proposal as the publish date", %{editor: editor} do
      at = proposal_in(7)

      page =
        ContentTypes.create!("page", %{title: "Offer", proposed_publish_at: at}, actor: editor)

      {:ok, lv, _html} =
        live(log_in(build_conn(), authed_user(:admin)), ~p"/editor/content/page/#{page.id}")

      assert lv |> element("#proposed-publish-at-note") |> render() =~
               Calendar.strftime(at, "%-d %B %Y, %H:%M")

      assert has_element?(lv, "#use-proposed-publish-at")
      # The admin edits the real date, not the proposal.
      refute has_element?(lv, ~s{input[name="form[proposed_publish_at]"]})
    end
  end
end
