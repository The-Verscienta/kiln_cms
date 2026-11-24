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
  # async: false — "a peer's save cannot be silently clobbered by a session
  # mid-edit" flips `:collab_prototype` off, and that flag is global application
  # env read at mount by every editor session in the VM (`Crdt.enabled?/0`), not
  # something scoped to this test's processes. Run async, that flip switched
  # collaboration off underneath whatever else happened to be mounting an editor
  # at that moment. A session that mounts with the flag off never stands down,
  # so `KilnCMSWeb.CollabPersisterTest` got an ordinary autosave where it
  # expected "Synced live", and `KilnCMSWeb.CollabFragmentTest` lost its
  # `data-collab-fragment` attributes entirely (`@collab_token` is nil, so the
  # attribute is not rendered at all). Both failed only under a full run, passed
  # in isolation, and moved between tests with the seed — the shape a
  # global-state leak takes, not the presence race it reads as.
  # `KilnCMSWeb.CollabChannelTest` is sync for the same reason.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import KilnCMS.TipTapFixtures

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.WorkingCopy

  @password "password123456"

  defp authed_user(role \\ :editor) do
    email = "csr-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp slug, do: "csr-#{System.unique_integer([:positive])}"

  # Presence diffs and the saved broadcast both arrive asynchronously; never
  # assert on a fixed sleep. Deadline-based (#1349): the previous `tries` count
  # was exactly the budget shape ConnCase.eventually/4's docstring post-mortems.
  defp await(lv, fun) do
    KilnCMS.Test.Eventually.eventually(
      fn ->
        html = render(lv)
        fun.(html) && html
      end,
      message: fn -> "condition never held; last render:\n#{render(lv)}" end
    )
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

  # Production's default (`KilnCMS.Collab.CRDT.enabled?/0`): two editors are two
  # independent writers. VM-global, so only safe while this module is
  # `async: false` (see the note above `use`).
  defp collab_off do
    previous = Application.get_env(:kiln_cms, :collab_prototype)
    Application.put_env(:kiln_cms, :collab_prototype, false)
    on_exit(fn -> Application.put_env(:kiln_cms, :collab_prototype, previous) end)
  end

  defp two_sessions(conn, page, role \\ :editor) do
    editor_a = authed_user(role)
    editor_b = authed_user(role)

    {:ok, lv_a, _} = conn |> log_in(editor_a) |> live(~p"/editor/content/page/#{page.id}")
    {:ok, lv_b, _} = build_conn() |> log_in(editor_b) |> live(~p"/editor/content/page/#{page.id}")
    await(lv_b, &(&1 =~ "2 editing"))

    %{a: editor_a, lv_a: lv_a, lv_b: lv_b}
  end

  defp edit(lv, field, value) do
    lv
    |> form("#page-editor")
    |> render_change(%{"form" => %{field => value}, "_target" => ["form", field]})
  end

  defp rich_text_page(actor) do
    CMS.create_page!(
      %{title: "Alpha", slug: slug(), blocks: [%{"_type" => "rich_text", "legacy_html" => ""}]},
      actor: actor
    )
  end

  defp body_text(page, actor) do
    [%Ash.Union{value: %{body: [%{"children" => [%{"text" => text}]}]}}] =
      CMS.get_page!(page.id, actor: actor).blocks

    text
  end

  # The element id of the rich-text editor host, which carries the editor
  # generation: a new id is a TipTap remount.
  defp rich_host_id(lv) do
    [id] = Regex.run(~r/id="(rt-[^"]+)"/, render(lv), capture: :all_but_first)
    id
  end

  defp versions(page, actor) do
    CMS.list_page_versions!(actor: actor)
    |> Enum.filter(&(&1.version_source_id == page.id))
    |> Enum.sort_by(& &1.version_inserted_at, DateTime)
  end

  # How many rows this session's OWN version panel is rendering — one
  # `toggle_compare` control per version.
  defp version_rows(lv),
    do: lv |> render() |> String.split(~s(phx-click="toggle_compare")) |> length()

  # Asserted on the CO-EDITOR'S OWN RENDER, not on the database. An earlier
  # version of this test counted rows with `versions/2` and then waited for
  # "Beta" to appear anywhere in the co-editor's HTML — which `@record` alone
  # satisfies. Removing `load_versions/1` from the refresh left it green.
  test "the co-editor's version list follows the persister's autosave", %{conn: conn} do
    page = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: authed_user())
    %{persister: persister, co_editor: co_editor} = both_present(conn, page)

    before = version_rows(co_editor)

    persister |> form("#page-editor", form: %{title: "Beta"}) |> render_change()
    send(persister.pid, :autosave)
    await(persister, &(&1 =~ "Saved"))

    # The panel grows without the co-editor doing anything.
    await(co_editor, fn _html -> version_rows(co_editor) > before end)
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

  # THE regression this fix originally shipped, and the reason `adopt_saved/2`
  # has a guard clause.
  #
  # `:autosave` carries `optimistic_lock(:lock_version)` and `do_autosave/1`
  # builds its changeset from `@record`. Advancing that assign while this
  # session's `@form` still holds older data handed the lock a version it
  # accepted — and the stale form then wrote straight over the peer's save, with
  # no conflict flash at all.
  #
  # Run with the collaboration prototype OFF, which is production's default
  # (`KilnCMS.Collab.CRDT.enabled?/0`). With it on, a non-persisting session
  # stands down instead of saving, so the lock is never reached and the bug is
  # invisible — the config the suite happens to run under was hiding it.
  #
  # The flag is VM-global, so this flip is only safe because the module is
  # `async: false` (see the note above `use`). Keep it that way: turning this
  # module async again silently breaks every other collab test that happens to
  # overlap it.
  #
  # Both sides edit the SAME field: `AshPhoenix.Form.params/1` is touched-only,
  # so sessions editing different fields merge harmlessly and prove nothing.
  test "a peer's save cannot be silently clobbered by a session mid-edit", %{conn: conn} do
    previous = Application.get_env(:kiln_cms, :collab_prototype)
    Application.put_env(:kiln_cms, :collab_prototype, false)
    on_exit(fn -> Application.put_env(:kiln_cms, :collab_prototype, previous) end)

    editor_a = authed_user()
    editor_b = authed_user()
    page = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: editor_a)

    {:ok, lv_a, _} = conn |> log_in(editor_a) |> live(~p"/editor/content/page/#{page.id}")
    {:ok, lv_b, _} = build_conn() |> log_in(editor_b) |> live(~p"/editor/content/page/#{page.id}")
    await(lv_b, &(&1 =~ "2 editing"))

    lv_b |> form("#page-editor", form: %{title: "From B"}) |> render_change()

    lv_a |> form("#page-editor", form: %{title: "From A"}) |> render_change()
    send(lv_a.pid, :autosave)
    await(lv_a, &(&1 =~ "Saved"))

    # B's autosave must fail the lock and say so, rather than reverting A.
    send(lv_b.pid, :autosave)
    await(lv_b, &(&1 =~ "changed elsewhere"))

    assert CMS.get_page!(page.id, actor: editor_a).title == "From A"
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

    before = version_rows(co_editor)

    persister |> form("#page-editor", form: %{title: "Beta"}) |> render_change()
    send(persister.pid, :autosave)
    await(persister, &(&1 =~ "Saved"))

    # The version panel still follows — it is read-only and cannot lose
    # anything. `@record` deliberately does NOT, because this session has an
    # edit in flight and its next save has to keep failing the optimistic lock.
    await(co_editor, fn _html -> version_rows(co_editor) > before end)

    assert render(co_editor) =~ "Typed by the co-editor"
  end

  # One person, two tabs. The first echo guard compared ACTOR ids, which made a
  # session's own second window look like an echo and skip the refresh — so the
  # reported symptom still reproduced for one person with the document open
  # twice, which is at least as common as two people.
  test "a second tab of the same user is refreshed, not treated as an echo", %{conn: conn} do
    editor = authed_user()
    page = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: editor)

    {:ok, tab_one, _} = conn |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

    {:ok, tab_two, _} =
      build_conn() |> log_in(editor) |> live(~p"/editor/content/page/#{page.id}")

    tab_one |> form("#page-editor", form: %{title: "From tab one"}) |> render_change()
    send(tab_one.pid, :autosave)
    await(tab_one, &(&1 =~ "Saved"))

    await(tab_two, &(&1 =~ "From tab one"))
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

  # #2775. An idle session adopted the peer's lock version but kept its own
  # stale form, so its next edit posted that form whole (as the browser and
  # `render_change/2` both do) and the autosave wrote it over the peer's save
  # with no conflict. Now the idle session is rebuilt from the save.
  describe "an idle session, collaboration off" do
    setup do
      collab_off()
      :ok
    end

    test "takes in a peer's save, and its next edit keeps it", %{conn: conn} do
      page = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: authed_user())
      %{a: a, lv_a: lv_a, lv_b: lv_b} = two_sessions(conn, page)

      edit(lv_b, "title", "From B")
      send(lv_b.pid, :autosave)
      await(lv_a, &(&1 =~ ~s(value="From B")))

      edit(lv_a, "seo_title", "From A")
      send(lv_a.pid, :autosave)
      await(lv_a, &(&1 =~ "Saved"))

      saved = CMS.get_page!(page.id, actor: a)
      assert saved.title == "From B"
      assert saved.seo_title == "From A"
    end

    test "takes in a peer's rich-text body, and its next edit keeps it", %{conn: conn} do
      page = rich_text_page(authed_user())
      [%Ash.Union{value: block}] = page.blocks
      %{a: a, lv_a: lv_a, lv_b: lv_b} = two_sessions(conn, page)
      host = rich_host_id(lv_a)

      render_hook(lv_b, "rich_text_body", %{
        "id" => block.id,
        "idx" => "0",
        "doc" => doc([para("written by B")])
      })

      send(lv_b.pid, :autosave)
      # Without a collaboration room TipTap only shows what it was mounted
      # with, so the body reaches the screen through a remount.
      await(lv_a, fn _html -> rich_host_id(lv_a) != host end)

      edit(lv_a, "seo_title", "From A")
      send(lv_a.pid, :autosave)
      await(lv_a, &(&1 =~ "Saved"))

      assert body_text(page, a) == "written by B"
      assert CMS.get_page!(page.id, actor: a).seo_title == "From A"
    end

    # Unsaved Settings on a live page are not lost to a peer's text autosave:
    # they go back on the rebuilt form, as after this session's own autosave,
    # and its Save then holds them on top of the peer's text.
    test "keeps its unsaved Settings over a peer's text autosave", %{conn: conn} do
      admin = authed_user(:admin)
      page = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: admin)
      page = CMS.publish_page!(page, %{}, actor: admin)
      %{a: a, lv_a: lv_a, lv_b: lv_b} = two_sessions(conn, page)

      edit(lv_a, "seo_title", "Typed by A")

      edit(lv_b, "title", "From B")
      send(lv_b.pid, :autosave)
      html = await(lv_a, &(&1 =~ ~s(value="From B")))

      refute html =~ ~s(id="edit-conflict")
      assert has_element?(lv_a, ~s(input[name="form[seo_title]"][value="Typed by A"]))
      assert html =~ "Unsaved changes"

      html = lv_a |> form("#page-editor") |> render_submit()
      assert html =~ "Readers see these changes once you publish them."

      view = page.id |> CMS.get_page!(actor: a) |> WorkingCopy.view()
      assert view.title == "From B"
      assert view.seo_title == "Typed by A"
    end
  end

  describe "a session with unsaved text, collaboration off" do
    setup do
      collab_off()
      :ok
    end

    # Its next save would fail the lock anyway; the banner now comes at once,
    # rather than after more typing that cannot be saved. In review, so that
    # nothing autosaves: with a debounce timer running, the session's own
    # autosave would meet the lock and raise the banner either way.
    test "is told of a peer's save at once", %{conn: conn} do
      admin = authed_user(:admin)
      page = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: admin)
      page = CMS.submit_page_for_review!(page, %{}, actor: admin)
      %{a: a, lv_a: lv_a, lv_b: lv_b} = two_sessions(conn, page, :admin)

      edit(lv_a, "title", "From A")
      assert render(lv_a) =~ "Unsaved changes"

      edit(lv_b, "title", "From B")
      lv_b |> form("#page-editor") |> render_submit()

      await(lv_a, &(&1 =~ ~s(id="edit-conflict")))
      assert has_element?(lv_a, ~s(input[name="form[title]"][value="From A"]))
      assert CMS.get_page!(page.id, actor: a).title == "From B"
    end
  end

  describe "collaboration on" do
    # The co-editor's explicit Save of a field outside the shared document
    # reaches the idle persister's form, without remounting its rich-text
    # editor (bound to the shared document, which the write did not change);
    # the persister's next autosave then keeps it.
    test "the idle persister takes in a co-editor's Save", %{conn: conn} do
      page = rich_text_page(authed_user())
      %{low: low, persister: persister, co_editor: co_editor} = both_present(conn, page)
      host = rich_host_id(persister)

      edit(co_editor, "seo_title", "Saved by the co-editor")
      co_editor |> form("#page-editor") |> render_submit()

      await(persister, &(&1 =~ ~s(value="Saved by the co-editor")))
      assert rich_host_id(persister) == host

      edit(persister, "title", "Beta")
      send(persister.pid, :autosave)
      await(persister, &(&1 =~ "Saved"))

      saved = CMS.get_page!(page.id, actor: low)
      assert saved.title == "Beta"
      assert saved.seo_title == "Saved by the co-editor"
    end

    # The persister writes the shared text for everyone, so a session with text
    # in flight is not stopped by a banner: the collab path is as it was.
    test "a persister with text in flight gets no banner", %{conn: conn} do
      page = CMS.create_page!(%{title: "Alpha", slug: slug()}, actor: authed_user())
      %{persister: persister, co_editor: co_editor} = both_present(conn, page)

      edit(persister, "title", "Beta")
      before = version_rows(persister)

      edit(co_editor, "seo_title", "Saved by the co-editor")
      co_editor |> form("#page-editor") |> render_submit()

      await(persister, fn _html -> version_rows(persister) > before end)
      refute has_element?(persister, "#edit-conflict")
      assert has_element?(persister, ~s(input[name="form[title]"][value="Beta"]))
    end
  end
end
