defmodule KilnCMSWeb.ContentEditorSuggestTest do
  @moduledoc """
  The "Suggest with AI" flow in the content editor (#60): async generation,
  per-field accept, and the guards that stop a generated string reaching a
  published `<meta>` tag by accident.

  Swaps global app env to select a stub generator, so `async: false`.
  **No test here makes a network call** — the shipped ReqLLM adapter is never
  selected.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMSWeb.Presence

  @password "password123456"

  defp authed_user(role) do
    email = "seo-suggest-#{System.unique_integer([:positive])}@example.com"

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

  defp open_editor(conn, user, page) do
    {:ok, lv, html} = conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")
    {lv, html}
  end

  defp put_seo(overrides) do
    previous = Application.get_env(:kiln_cms, KilnCMS.Seo, [])
    Application.put_env(:kiln_cms, KilnCMS.Seo, Keyword.merge(previous, overrides))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Seo, previous) end)
  end

  defp enable_stub(generator \\ KilnCMS.StubSeoGenerator),
    do: put_seo(generator: generator, model: "stub:stub")

  # Long enough to clear KilnCMS.Seo.min_words/0.
  defp prose_blocks do
    body =
      for i <- 1..8 do
        %{
          "_type" => "block",
          "style" => "normal",
          "children" => [
            %{
              "text" =>
                "Step #{i} is simple. Load the shelves with care. " <>
                  "Set the ramp rate low for the first hour. Watch the cones as the heat climbs."
            }
          ]
        }
      end

    [%{"_type" => "rich_text", "body" => body}]
  end

  defp page(attrs \\ %{}, actor) do
    CMS.create_page!(
      Map.merge(
        %{
          title: "Understanding kiln firing",
          slug: "suggest-#{System.unique_integer([:positive])}",
          blocks: prose_blocks()
        },
        attrs
      ),
      actor: actor
    )
  end

  defp change(lv, field, params) do
    render_change(lv, "validate", %{"form" => params, "_target" => ["form", field]})
  end

  # How many suggestion cards are currently offered.
  defp cards(html),
    do: html |> String.split(~s(phx-click="seo_accept")) |> length() |> Kernel.-(1)

  defp field_value(lv, field) do
    html = lv |> element(~s([name="form[#{field}]"])) |> render()

    case Regex.run(~r/\bvalue="([^"]*)"/, html, capture: :all_but_first) do
      [value] -> value
      # Textareas carry their value as content, not an attribute.
      nil -> html |> String.replace(~r/<[^>]*>/, "") |> String.trim()
    end
  end

  describe "gating" do
    test "the control is absent when no generator is configured", %{conn: conn} do
      editor = authed_user(:editor)
      {_lv, html} = open_editor(conn, editor, page(editor))

      refute html =~ "Suggest with AI"
    end

    test "the control appears once a generator is configured", %{conn: conn} do
      enable_stub()
      editor = authed_user(:editor)
      {_lv, html} = open_editor(conn, editor, page(editor))

      assert html =~ "Suggest with AI"
    end
  end

  describe "the egress notice" do
    test "is absent for an on-prem provider", %{conn: conn} do
      put_seo(generator: KilnCMS.StubSeoGenerator, model: "ollama:llama3.1")
      editor = authed_user(:editor)
      {_lv, html} = open_editor(conn, editor, page(editor))

      assert html =~ "Suggest with AI"
      refute html =~ "sent to that provider"
    end

    test "names the provider for a hosted one", %{conn: conn} do
      put_seo(generator: KilnCMS.StubSeoGenerator, model: "anthropic:claude-sonnet-5")
      editor = authed_user(:editor)
      {_lv, html} = open_editor(conn, editor, page(editor))

      assert html =~ "sent to that provider"
      assert html =~ "anthropic"
    end
  end

  describe "generating" do
    setup do
      enable_stub()
      :ok
    end

    test "suggestions appear after the async run completes", %{conn: conn} do
      editor = authed_user(:editor)
      {lv, _html} = open_editor(conn, editor, page(editor))

      render_click(lv, "seo_suggest", %{})
      html = render_async(lv, 2_000)

      assert html =~ "SEO: Understanding kiln firing"
      assert html =~ "Suggestions"
    end

    test "a second click while one is in flight does not start a second run", %{conn: conn} do
      # The disabled attribute is client-side only, so a fast double-click or a
      # replayed event would otherwise generate — and bill — twice.
      put_seo(generator: KilnCMS.StubSeoGenerator.Counting, model: "stub:stub")
      {:ok, _} = KilnCMS.StubSeoGenerator.Counting.start_link()
      KilnCMS.StubSeoGenerator.Counting.reset()

      editor = authed_user(:editor)
      {lv, _html} = open_editor(conn, editor, page(editor))

      render_click(lv, "seo_suggest", %{})
      # Still in flight (the Counting stub sleeps), so this one must be ignored.
      render_click(lv, "seo_suggest", %{})
      render_async(lv, 5_000)

      assert KilnCMS.StubSeoGenerator.Counting.count() == 1
    end

    test "a page with too little content is refused before reaching the provider",
         %{conn: conn} do
      editor = authed_user(:editor)
      thin = page(%{blocks: [%{"_type" => "heading", "text" => "Hi", "level" => 2}]}, editor)
      {lv, _html} = open_editor(conn, editor, thin)

      render_click(lv, "seo_suggest", %{})
      html = render_async(lv, 2_000)

      assert html =~ "isn&#39;t enough content yet"
      refute html =~ "SEO: Understanding"
    end
  end

  describe "failure paths clear the spinner" do
    test "a generator error flashes and leaves the fields untouched", %{conn: conn} do
      enable_stub(KilnCMS.StubSeoGenerator.Failing)
      editor = authed_user(:editor)
      {lv, _html} = open_editor(conn, editor, page(editor))

      render_click(lv, "seo_suggest", %{})
      html = render_async(lv, 2_000)

      assert html =~ "Couldn&#39;t generate suggestions"
      assert field_value(lv, "seo_title") == ""

      # Not stuck: the control is enabled again, so the author can retry. (The
      # spinner class alone is a poor probe — the save indicator uses it too.)
      button = lv |> element("button[phx-click='seo_suggest']") |> render()
      refute button =~ "disabled"
    end

    test "a generator that raises degrades without taking the editor down", %{conn: conn} do
      enable_stub(KilnCMS.StubSeoGenerator.Raising)
      editor = authed_user(:editor)
      {lv, _html} = open_editor(conn, editor, page(editor))

      render_click(lv, "seo_suggest", %{})
      html = render_async(lv, 2_000)

      assert html =~ "Couldn&#39;t generate suggestions"
      assert render(lv) =~ "SEO &amp; scheduling"
    end
  end

  describe "accepting" do
    setup do
      enable_stub()
      :ok
    end

    defp suggest(conn, editor, record) do
      {lv, _html} = open_editor(conn, editor, record)
      render_click(lv, "seo_suggest", %{})
      render_async(lv, 2_000)
      lv
    end

    test "accepting one field writes only that field", %{conn: conn} do
      editor = authed_user(:editor)
      lv = suggest(conn, editor, page(editor))

      render_click(lv, "seo_accept", %{"field" => "seo_title"})

      assert field_value(lv, "seo_title") == "SEO: Understanding kiln firing"
      assert field_value(lv, "seo_description") == ""
    end

    test "an accepted card stops offering itself", %{conn: conn} do
      editor = authed_user(:editor)
      lv = suggest(conn, editor, page(editor))

      # Count the cards rather than matching on a label: "SEO title" is also
      # the permanent label of the seo_title input itself.
      before_count = render(lv) |> cards()
      html = render_click(lv, "seo_accept", %{"field" => "seo_title"})

      assert cards(html) == before_count - 1
    end

    test "dismissing leaves the field alone", %{conn: conn} do
      editor = authed_user(:editor)
      lv = suggest(conn, editor, page(editor))

      render_click(lv, "seo_dismiss", %{"field" => "seo_title"})
      assert field_value(lv, "seo_title") == ""
    end

    test "accept-all applies every proposal", %{conn: conn} do
      editor = authed_user(:editor)
      lv = suggest(conn, editor, page(editor))

      render_click(lv, "seo_accept_all", %{})

      assert field_value(lv, "seo_title") == "SEO: Understanding kiln firing"
      assert field_value(lv, "seo_description") =~ "A summary of"
      assert field_value(lv, "seo_keywords") == "stub keyphrase, second"
    end

    test "an accepted value still saves", %{conn: conn} do
      editor = authed_user(:editor)
      record = page(editor)
      lv = suggest(conn, editor, record)

      render_click(lv, "seo_accept", %{"field" => "seo_title"})
      lv |> form("#page-editor") |> render_submit()

      assert Ash.get!(CMS.Page, record.id, actor: editor).seo_title ==
               "SEO: Understanding kiln firing"
    end
  end

  describe "suggestions are discarded when the content underneath them is" do
    setup do
      enable_stub()
      :ok
    end

    test "a conflict reload drops the cards it just invalidated", %{conn: conn} do
      # "Reload and discard your unsaved changes" must discard the AI proposal
      # too — it was generated from the content being thrown away, and the
      # reload clears :conflict, which is the guard accept/2 relies on.
      editor = authed_user(:editor)
      record = page(editor)
      lv = suggest(conn, editor, record)

      assert cards(render(lv)) > 0

      render_click(lv, "reload_conflict", %{})

      assert cards(render(lv)) == 0
      render_click(lv, "seo_accept_all", %{})
      assert field_value(lv, "seo_title") == ""
    end

    test "re-running Suggest does not resurrect the previous run's cards", %{conn: conn} do
      editor = authed_user(:editor)
      lv = suggest(conn, editor, page(editor))

      render_click(lv, "seo_accept", %{"field" => "seo_title"})
      # Hand-edit what was just accepted.
      change(lv, "seo_title", %{"seo_title" => "My own headline"})

      # Swap in the slow stub so the second run is genuinely in flight while we
      # look: with an instant stub the new proposal lands before we can observe
      # the window this regression lived in.
      put_seo(generator: KilnCMS.StubSeoGenerator.Counting, model: "stub:stub")
      {:ok, _} = KilnCMS.StubSeoGenerator.Counting.start_link()
      KilnCMS.StubSeoGenerator.Counting.reset()

      render_click(lv, "seo_suggest", %{})

      # Mid-generation there is nothing to apply — previously the *old* cards
      # were still rendered here, so this click clobbered the hand edit.
      assert cards(render(lv)) == 0
      render_click(lv, "seo_accept_all", %{})
      assert field_value(lv, "seo_title") == "My own headline"

      render_async(lv, 5_000)
      assert field_value(lv, "seo_title") == "My own headline"
    end
  end

  describe "Use all" do
    setup do
      enable_stub()
      :ok
    end

    test "leaves accepted and hand-edited fields alone", %{conn: conn} do
      editor = authed_user(:editor)
      lv = suggest(conn, editor, page(editor))

      render_click(lv, "seo_accept", %{"field" => "seo_title"})
      change(lv, "seo_title", %{"seo_title" => "My own headline"})

      render_click(lv, "seo_accept_all", %{})

      assert field_value(lv, "seo_title") == "My own headline"
      assert field_value(lv, "seo_description") =~ "A summary of"
    end

    test "skips a dismissed field", %{conn: conn} do
      editor = authed_user(:editor)
      lv = suggest(conn, editor, page(editor))

      render_click(lv, "seo_dismiss", %{"field" => "seo_title"})
      render_click(lv, "seo_accept_all", %{})

      assert field_value(lv, "seo_title") == ""
      assert field_value(lv, "seo_description") =~ "A summary of"
    end

    test "reports a locked field instead of letting a later flash hide it", %{conn: conn} do
      editor = authed_user(:editor)
      record = page(editor)
      lv = suggest(conn, editor, record)

      topic = Presence.topic("page", record.id)

      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        topic,
        {:cursor, %{id: "other", name: "bob", field: "seo_title"}}
      )

      html = render_click(lv, "seo_accept_all", %{})

      # The skipped field is named, and the keywords/slug message doesn't
      # overwrite it.
      assert html =~ "Another editor is editing SEO title"
      assert field_value(lv, "seo_title") == ""
      assert field_value(lv, "seo_description") =~ "A summary of"
    end
  end

  describe "the slug decision" do
    setup do
      enable_stub()
      :ok
    end

    test "accepting keywords on a never-published draft re-derives the slug", %{conn: conn} do
      # Mirrors what typing the same keywords does — there is no live URL to
      # break yet, so diverging from the typed behaviour would be surprising.
      editor = authed_user(:editor)

      draft =
        page(
          %{title: "Untitled page", slug: "untitled-#{System.unique_integer([:positive])}"},
          editor
        )

      lv = suggest(conn, editor, draft)

      render_click(lv, "seo_accept", %{"field" => "seo_keywords"})

      assert field_value(lv, "slug") == "stub-keyphrase"
    end

    test "accepting keywords on published content leaves the slug alone and says so",
         %{conn: conn} do
      # Silently moving a live URL because a model proposed a keyphrase would
      # be indefensible.
      admin = authed_user(:admin)
      record = page(%{slug: "live-url-page"}, admin)
      published = CMS.publish_page!(record, actor: admin)

      lv = suggest(conn, admin, published)
      html = render_click(lv, "seo_accept", %{"field" => "seo_keywords"})

      assert field_value(lv, "slug") == "live-url-page"
      assert field_value(lv, "seo_keywords") == "stub keyphrase, second"
      assert html =~ "slug was left unchanged"
    end
  end

  describe "write-path guards" do
    setup do
      enable_stub()
      :ok
    end

    test "a peer holding the field blocks the accept server-side", %{conn: conn} do
      editor = authed_user(:editor)
      record = page(editor)
      lv = suggest(conn, editor, record)

      topic = Presence.topic("page", record.id)
      cursor = %{id: "other-editor", name: "bob", field: "seo_title"}
      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic, {:cursor, cursor})
      assert render(lv) =~ "ring-warning"

      # The lock is advisory — the input goes readonly but still submits — so
      # the disabled button is not the boundary. A replayed event lands here.
      html = render_click(lv, "seo_accept", %{"field" => "seo_title"})

      assert field_value(lv, "seo_title") == ""
      # The message names the field, so a multi-field "Use all" can report
      # exactly which ones were skipped rather than a generic notice.
      assert html =~ "Another editor is editing SEO title"

      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic, {:cursor, %{cursor | field: nil}})
      render_click(lv, "seo_accept", %{"field" => "seo_title"})
      assert field_value(lv, "seo_title") == "SEO: Understanding kiln firing"
    end

    test "an autosave landing mid-generation doesn't strand the suggestion", %{conn: conn} do
      # The suggestion lives in its own assign, and accept re-reads the form's
      # params at accept time rather than snapshotting them when generation
      # started — so a save that rebuilds the form (bumping lock_version) in
      # between must not lose the write.
      editor = authed_user(:editor)
      record = page(editor)
      lv = suggest(conn, editor, record)

      lv |> form("#page-editor", form: %{title: "Retitled mid-flight"}) |> render_submit()

      render_click(lv, "seo_accept", %{"field" => "seo_title"})
      assert field_value(lv, "seo_title") == "SEO: Understanding kiln firing"

      lv |> form("#page-editor") |> render_submit()
      saved = Ash.get!(CMS.Page, record.id, actor: editor)

      assert saved.seo_title == "SEO: Understanding kiln firing"
      assert saved.title == "Retitled mid-flight"
    end
  end
end
