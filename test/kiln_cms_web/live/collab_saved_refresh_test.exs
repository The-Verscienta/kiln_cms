defmodule KilnCMSWeb.CollabSavedRefreshTest do
  @moduledoc """
  A co-editor's view of the *saved* record follows the persister's writes (#694).

  Under active collaboration only the elected persister autosaves — everyone else
  stands down (`KilnCMSWeb.CollabPersisterTest`). The cost was that a
  non-persisting session's `assign_record/2` never ran again, so its `@record`
  and `@versions` stayed at whatever they were on mount: the version list quietly
  stopped growing, and the version-compare modal (#467) turned that into a
  confidently wrong statement — "These two versions are identical" about a
  document that had since changed.

  A `{:record_saved, actor_id}` broadcast on the Presence editing topic now makes
  those sessions re-read. What they must NOT re-read is their own in-flight
  edits, which is asserted here too: refreshing the form on someone else's save
  would throw away what the person is typing, a worse bug than the one being
  fixed.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user do
    email = "csr-#{System.unique_integer([:positive])}@example.com"

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

  defp slug, do: "csr-#{System.unique_integer([:positive])}"

  # Presence diffs and the saved broadcast both arrive asynchronously; never
  # assert on a fixed sleep.
  defp await(lv, fun, tries \\ 60) do
    html = render(lv)

    cond do
      fun.(html) ->
        html

      tries == 0 ->
        flunk("condition never held; last render:\n#{html}")

      true ->
        Process.sleep(25)
        await(lv, fun, tries - 1)
    end
  end

  # The persister is the lowest user id among those present — the same
  # deterministic election the advisory field locks use.
  defp two_editors do
    a = authed_user()
    b = authed_user()
    {Enum.min_by([a, b], & &1.id), Enum.max_by([a, b], & &1.id)}
  end

  defp both_present(conn, page) do
    {low, high} = two_editors()

    {:ok, lv_low, _} = conn |> log_in(low) |> live(~p"/editor/content/page/#{page.id}")
    {:ok, lv_high, _} = build_conn() |> log_in(high) |> live(~p"/editor/content/page/#{page.id}")

    await(lv_low, &(&1 =~ "2 editing"))
    await(lv_high, &(&1 =~ "2 editing"))

    %{low: low, high: high, persister: lv_low, co_editor: lv_high}
  end

  defp pick(lv, id), do: render_click(lv, "toggle_compare", %{"version_id" => id})

  defp versions(page, actor) do
    CMS.list_page_versions!(actor: actor)
    |> Enum.filter(&(&1.version_source_id == page.id))
    |> Enum.sort_by(& &1.version_inserted_at, DateTime)
  end

  test "the co-editor's version list follows the persister's autosave", %{conn: conn} do
    page = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: authed_user())
    %{low: low, persister: persister, co_editor: co_editor} = both_present(conn, page)

    before = length(versions(page, low))

    persister |> form("#page-editor", form: %{title: "Beta"}) |> render_change()
    send(persister.pid, :autosave)
    await(persister, &(&1 =~ "Saved"))

    # The write really landed, so the co-editor's list is now provably behind.
    assert length(versions(page, low)) > before

    # And it catches up without the co-editor doing anything.
    await(co_editor, &(&1 =~ "Beta"))
  end

  # The bug as #694 reported it: the modal states a conclusion, and the
  # conclusion was about a document that no longer existed.
  test "the compare modal does not call a changed draft identical", %{conn: conn} do
    page = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: authed_user())
    %{low: low, persister: persister, co_editor: co_editor} = both_present(conn, page)

    [creation | _] = versions(page, low)

    pick(co_editor, creation.id)
    pick(co_editor, "current")
    assert render_click(co_editor, "open_compare", %{}) =~ "Compare versions"

    persister |> form("#page-editor", form: %{title: "Beta"}) |> render_change()
    send(persister.pid, :autosave)
    await(persister, &(&1 =~ "Saved"))

    # The comparison recomputes through `refresh_compare/2`, so the co-editor's
    # open modal now reports the change instead of denying it.
    html = await(co_editor, &(&1 =~ "Beta"))
    assert html =~ "Compare versions"
    refute html =~ "These two versions are identical"
  end

  # The line this fix must not cross. In a collab session the co-editor's own
  # edits live in their form (and, for text, in the shared Y.Doc) — not in the
  # record that was just written. Rebuilding the form on someone else's save
  # would silently discard what they are typing.
  test "the co-editor's own unsaved edits survive the refresh", %{conn: conn} do
    page = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: authed_user())
    %{persister: persister, co_editor: co_editor} = both_present(conn, page)

    co_editor
    |> form("#page-editor", form: %{seo_title: "Typed by the co-editor"})
    |> render_change()

    persister |> form("#page-editor", form: %{title: "Beta"}) |> render_change()
    send(persister.pid, :autosave)
    await(persister, &(&1 =~ "Saved"))
    await(co_editor, &(&1 =~ "Beta"))

    assert render(co_editor) =~ "Typed by the co-editor"
  end

  # Not a test of the echo guard — a solo re-read would be wasteful, not wrong,
  # so nothing here can observe it. What this pins is that adding a broadcast to
  # every persisting write left the single-editor path exactly as it was: the
  # session receives its own message and its in-flight edits are still there.
  test "a solo editor's autosave still behaves as before", %{conn: conn} do
    editor = authed_user()
    page = CMS.create_page!(%{title: "Solo", slug: slug()}, actor: editor)

    {:ok, lv, _} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

    lv |> form("#page-editor", form: %{seo_title: "Untouched"}) |> render_change()
    send(lv.pid, :autosave)
    await(lv, &(&1 =~ "Saved"))

    assert render(lv) =~ "Untouched"
  end
end
